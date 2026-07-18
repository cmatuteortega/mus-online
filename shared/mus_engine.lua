-- Mus rules engine — pure Lua, no Love2D, no sockets.
-- Runs authoritatively on the server; clients only ever receive viewFor(seat).
-- Headless tests: tests/test_mus_engine.lua (plain lua).
--
-- Model (see MUS_MIGRATION_PLAN.md §4):
--   4 seats, partners across: team 1 = seats {1,3}, team 2 = seats {2,4}.
--   Hand flow: deal → mus/discard rounds → Grande → Chica → Pares → Juego
--   (Punto when nobody has juego) → showdown scoring in piedras.
--   Pares/Juego "declarations" are derived from the cards (they are not a
--   choice in mus), so the engine announces them itself.
--
-- Documented simplifications for v1:
--   * All four hands are revealed at showdown (real mus only shows what's
--     contested).
--   * Señas are not modeled here — they travel as emotes outside the engine.

local MusEngine = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- RNG (deterministic LCG — same recipe as server/database.lua)
-- ──────────────────────────────────────────────────────────────────────────────

local function newRng(seed)
    local s = (tonumber(seed) or 42) % 2147483648
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return (s % n) + 1
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Cards
-- ──────────────────────────────────────────────────────────────────────────────

local SUITS = { "oros", "copas", "espadas", "bastos" }
-- Canonical ranks: 1..7, 10 = sota, 11 = caballo, 12 = rey.
local RANKS = { 1, 2, 3, 4, 5, 6, 7, 10, 11, 12 }

-- Strength for Grande/Chica/Pares ordering. With the 8-kings variant (reyes8)
-- threes count as kings and twos as aces — a 3 pairs with a rey.
local function strength(rank, cfg)
    if cfg.reyes8 then
        if rank == 3 then rank = 12 end
        if rank == 2 then rank = 1 end
    end
    local map = { [1]=1, [2]=2, [4]=3, [5]=4, [6]=5, [7]=6, [10]=7, [11]=8, [12]=9, [3]=3.5 }
    -- Without reyes8, 2 sits between as and 4, 3 between 2 and 4; use raw order.
    if cfg.reyes8 then
        return map[rank]
    end
    local plain = { [1]=1, [2]=2, [3]=3, [4]=4, [5]=5, [6]=6, [7]=7, [10]=8, [11]=9, [12]=10 }
    return plain[rank]
end

-- Juego points: figures (sota/caballo/rey, and 3 with reyes8) are worth 10.
local function points(rank, cfg)
    if rank >= 10 then return 10 end
    if cfg.reyes8 and rank == 3 then return 10 end
    if cfg.reyes8 and rank == 2 then return 1 end
    return rank
end

local function teamOf(seat) return (seat % 2 == 1) and 1 or 2 end

local function newDeck()
    local deck = {}
    for _, suit in ipairs(SUITS) do
        for _, rank in ipairs(RANKS) do
            deck[#deck + 1] = { rank = rank, suit = suit }
        end
    end
    return deck
end

local function shuffle(cards, rng)
    for i = #cards, 2, -1 do
        local j = rng(i)
        cards[i], cards[j] = cards[j], cards[i]
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Hand evaluation
-- ──────────────────────────────────────────────────────────────────────────────

-- Sorted strengths, descending (Grande order).
local function sortedStrengths(cards, cfg)
    local s = {}
    for i, c in ipairs(cards) do s[i] = strength(c.rank, cfg) end
    table.sort(s, function(a, b) return a > b end)
    return s
end

-- Grande: lexicographic on descending strengths, higher wins. Returns 1 if a
-- beats b, -1 if b beats a, 0 tie.
local function cmpGrande(a, b, cfg)
    local sa, sb = sortedStrengths(a, cfg), sortedStrengths(b, cfg)
    for i = 1, 4 do
        if sa[i] ~= sb[i] then return sa[i] > sb[i] and 1 or -1 end
    end
    return 0
end

-- Chica: lexicographic on ascending strengths, lower wins.
local function cmpChica(a, b, cfg)
    local sa, sb = sortedStrengths(a, cfg), sortedStrengths(b, cfg)
    for i = 4, 1, -1 do
        if sa[i] ~= sb[i] then return sa[i] < sb[i] and 1 or -1 end
    end
    return 0
end

-- Pares classification: returns nil (nothing) or
-- { class = 1 par | 2 medias | 3 duples, high, low }
local function paresOf(cards, cfg)
    local counts = {}
    for _, c in ipairs(cards) do
        local s = strength(c.rank, cfg)
        counts[s] = (counts[s] or 0) + 1
    end
    local pairsList, trips, quads = {}, {}, {}
    for s, n in pairs(counts) do
        if n == 4 then quads[#quads + 1] = s
        elseif n == 3 then trips[#trips + 1] = s
        elseif n == 2 then pairsList[#pairsList + 1] = s end
    end
    table.sort(pairsList, function(a, b) return a > b end)
    if #quads == 1 then
        return { class = 3, high = quads[1], low = quads[1] }        -- duples
    elseif #pairsList == 2 then
        return { class = 3, high = pairsList[1], low = pairsList[2] } -- duples
    elseif #trips == 1 then
        -- medias; a leftover pair is impossible with 4 cards
        return { class = 2, high = trips[1], low = 0 }
    elseif #pairsList == 1 then
        return { class = 1, high = pairsList[1], low = 0 }
    end
    return nil
end

local function cmpPares(a, b, cfg)
    local pa, pb = paresOf(a, cfg), paresOf(b, cfg)
    if pa.class ~= pb.class then return pa.class > pb.class and 1 or -1 end
    if pa.high ~= pb.high then return pa.high > pb.high and 1 or -1 end
    if pa.low ~= pb.low then return pa.low > pb.low and 1 or -1 end
    return 0
end

local function pointsOf(cards, cfg)
    local sum = 0
    for _, c in ipairs(cards) do sum = sum + points(c.rank, cfg) end
    return sum
end

local function hasJuego(cards, cfg) return pointsOf(cards, cfg) >= 31 end

-- Juego order: 31 best, then 32, then 40 down to 33.
local JUEGO_ORDER = { [31]=1, [32]=2, [40]=3, [39]=4, [38]=5, [37]=6, [36]=7, [35]=8, [34]=9, [33]=10 }

local function cmpJuego(a, b, cfg)
    local ra = JUEGO_ORDER[pointsOf(a, cfg)]
    local rb = JUEGO_ORDER[pointsOf(b, cfg)]
    if ra ~= rb then return ra < rb and 1 or -1 end
    return 0
end

local function cmpPunto(a, b, cfg)
    local pa, pb = pointsOf(a, cfg), pointsOf(b, cfg)
    if pa ~= pb then return pa > pb and 1 or -1 end
    return 0
end

-- Bonus piedras a single hand is worth when its team wins the phase.
local function paresBonus(cards, cfg)
    local p = paresOf(cards, cfg)
    if not p then return 0 end
    return p.class == 3 and 3 or (p.class == 2 and 2 or 1)
end

local function juegoBonus(cards, cfg)
    local pts = pointsOf(cards, cfg)
    if pts < 31 then return 0 end
    return pts == 31 and 3 or 2
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Match / hand state
-- ──────────────────────────────────────────────────────────────────────────────

local DEFAULT_CONFIG = {
    reyes8        = true,  -- 3s count as kings, 2s as aces
    targetPiedras = 40,    -- first team to reach this wins
}

function MusEngine.newMatch(config, seed)
    local cfg = {}
    for k, v in pairs(DEFAULT_CONFIG) do cfg[k] = v end
    for k, v in pairs(config or {}) do cfg[k] = v end
    return {
        cfg        = cfg,
        rng        = newRng(seed),
        scores     = { [1] = 0, [2] = 0 },
        manoSeat   = 1,
        handNo     = 0,
        winner     = nil,
        hand       = nil,
    }
end

-- Speaking order: mano first, then clockwise (seat+1 wraps).
local function speakOrder(manoSeat)
    local order = {}
    for i = 0, 3 do order[#order + 1] = ((manoSeat - 1 + i) % 4) + 1 end
    return order
end

-- Position of a seat in mano order (1 = mano) — used for tie-breaks.
local function manoIndex(match, seat)
    for i, s in ipairs(match.hand.order) do
        if s == seat then return i end
    end
end

local function draw(match)
    local hand = match.hand
    if #hand.deck == 0 then
        -- Reshuffle the discard pile back in.
        hand.deck, hand.discards = hand.discards, {}
        shuffle(hand.deck, match.rng)
    end
    return table.remove(hand.deck)
end

local PHASES = { "grande", "chica", "pares", "juego" }

function MusEngine.startHand(match)
    match.handNo = match.handNo + 1
    if match.handNo > 1 then
        match.manoSeat = (match.manoSeat % 4) + 1
    end
    local deck = newDeck()
    shuffle(deck, match.rng)

    local hand = {
        order     = speakOrder(match.manoSeat),
        deck      = deck,
        discards  = {},
        cards     = {},      -- [seat] = {4 cards}
        stage     = "mus",
        musIdx    = 1,       -- walker over hand.order during the mus round
        pendingDiscards = nil,
        betting   = nil,
        results   = {},      -- [phase] = result record
        revealed  = false,
        awards    = {},      -- log of piedra awards this hand
    }
    for seat = 1, 4 do
        local c = {}
        for _ = 1, 4 do c[#c + 1] = table.remove(deck) end
        hand.cards[seat] = c
    end
    match.hand = hand

    local events = {
        { to = "all", name = "hand_start", data = {
            hand_no = match.handNo, mano_seat = match.manoSeat,
            scores = { match.scores[1], match.scores[2] } } },
    }
    for seat = 1, 4 do
        events[#events + 1] = { to = seat, name = "your_cards", data = { cards = hand.cards[seat] } }
    end
    events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
    return events
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Awards / game end
-- ──────────────────────────────────────────────────────────────────────────────

local function award(match, team, n, reason, events)
    if n <= 0 or match.winner then return end
    match.scores[team] = match.scores[team] + n
    table.insert(match.hand.awards, { team = team, piedras = n, reason = reason })
    events[#events + 1] = { to = "all", name = "score", data = {
        team = team, piedras = n, reason = reason,
        scores = { match.scores[1], match.scores[2] } } }
    if match.scores[team] >= match.cfg.targetPiedras then
        match.winner = team
        events[#events + 1] = { to = "all", name = "game_end", data = { winner_team = team,
            scores = { match.scores[1], match.scores[2] } } }
    end
end

local function winGameOutright(match, team, reason, events)
    if match.winner then return end
    match.winner = team
    events[#events + 1] = { to = "all", name = "game_end", data = { winner_team = team, ordago = true,
        reason = reason, scores = { match.scores[1], match.scores[2] } } }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Phase participants & comparisons
-- ──────────────────────────────────────────────────────────────────────────────

local function comparatorFor(phase)
    if phase == "grande" then return cmpGrande end
    if phase == "chica" then return cmpChica end
    if phase == "pares" then return cmpPares end
    if phase == "juego" then return cmpJuego end
    if phase == "punto" then return cmpPunto end
end

-- Participants in mano order. For pares/juego only holders take part;
-- grande/chica/punto involve everyone.
local function participantsFor(match, phase)
    local hand = match.hand
    local out = {}
    for _, seat in ipairs(hand.order) do
        local cards = hand.cards[seat]
        local ok = true
        if phase == "pares" then ok = paresOf(cards, match.cfg) ~= nil end
        if phase == "juego" then ok = hasJuego(cards, match.cfg) end
        if ok then out[#out + 1] = seat end
    end
    return out
end

-- Best seat among participants for a phase (mano-order tie-break is implicit:
-- we scan in mano order and only replace on a strict win).
local function bestSeat(match, phase, participants)
    local cmp = comparatorFor(phase)
    local best = nil
    for _, seat in ipairs(participants) do
        if not best then
            best = seat
        elseif cmp(match.hand.cards[seat], match.hand.cards[best], match.cfg) == 1 then
            best = seat
        end
    end
    return best
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Betting state machine
-- ──────────────────────────────────────────────────────────────────────────────

-- One betting round for `phase` (phase may be "punto"):
--   open mode: participants speak in mano order — paso / envido N / órdago.
--   responding mode: after a bet, opposing participants respond in order —
--   quiero / no quiero / raise / órdago. A raise implicitly accepts the
--   previous stake (that amount is scored if the raise is then rejected).
local function newBetting(match, phase, participants)
    return {
        phase        = phase,
        participants = participants,
        mode         = "open",
        openIdx      = 1,
        agreedResult = nil,
        proposed     = 0,
        fallback     = 1,      -- scored by proposer team if their bet is rejected
        proposerTeam = nil,
        isOrdago     = false,
        responders   = nil,
        respIdx      = 1,
    }
end

local function bothTeamsIn(participants)
    local t = {}
    for _, s in ipairs(participants) do t[teamOf(s)] = true end
    return t[1] and t[2]
end

local function respondersFor(bet, biddingTeam)
    local out = {}
    for _, s in ipairs(bet.participants) do
        if teamOf(s) ~= biddingTeam then out[#out + 1] = s end
    end
    return out
end

local function bettingCurrentSeat(bet)
    if bet.mode == "open" then return bet.participants[bet.openIdx] end
    return bet.responders[bet.respIdx]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Stage progression
-- ──────────────────────────────────────────────────────────────────────────────

local advanceStage  -- forward decl

-- Record the outcome of a finished betting round and move on.
local function finishBetting(match, outcome, events)
    local hand = match.hand
    local bet = hand.betting
    hand.results[bet.phase] = outcome
    events[#events + 1] = { to = "all", name = "phase_result", data = {
        phase = bet.phase,
        outcome = outcome.kind,          -- "paso" | "accepted" | "rejected" | "ordago"
        amount = outcome.amount,
        team = outcome.team,
    } }
    -- A rejected bet scores immediately.
    if outcome.kind == "rejected" then
        award(match, outcome.team, outcome.amount, bet.phase .. " no querido", events)
    end
    hand.betting = nil
    if not match.winner then
        advanceStage(match, events)
    end
end

-- Start betting for the next phase, or skip it per the rules.
local function startPhase(match, phase, events)
    local hand = match.hand
    hand.stage = phase   -- set before any early return so advanceStage never re-enters
    local participants = participantsFor(match, phase)

    if phase == "pares" or phase == "juego" then
        -- Announce who holds pares/juego (derived from cards, not a choice).
        local decl = {}
        for _, seat in ipairs(hand.order) do
            local has
            if phase == "pares" then has = paresOf(hand.cards[seat], match.cfg) ~= nil
            else has = hasJuego(hand.cards[seat], match.cfg) end
            decl[#decl + 1] = { seat = seat, has = has }
        end
        events[#events + 1] = { to = "all", name = "declarations", data = { phase = phase, decl = decl } }

        if phase == "juego" and #participants == 0 then
            -- Nobody has juego → punto round instead, everyone in.
            hand.stage = "punto"
            hand.betting = newBetting(match, "punto", participantsFor(match, "punto"))
            events[#events + 1] = { to = "all", name = "stage", data = { stage = "punto" } }
            events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
            return
        end
        if not bothTeamsIn(participants) then
            -- One team (or nobody) holds it: no betting; bonuses at showdown.
            hand.results[phase] = { kind = "uncontested" }
            events[#events + 1] = { to = "all", name = "phase_result", data = { phase = phase, outcome = "uncontested" } }
            return advanceStage(match, events)
        end
    end

    hand.stage = phase
    hand.betting = newBetting(match, phase, participants)
    events[#events + 1] = { to = "all", name = "stage", data = { stage = phase } }
    events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
end

-- Showdown: reveal hands, resolve accepted bets and bonuses, end the hand.
local function showdown(match, events)
    local hand = match.hand
    hand.stage = "showdown"
    hand.revealed = true

    local reveal = {}
    for seat = 1, 4 do reveal[seat] = hand.cards[seat] end
    events[#events + 1] = { to = "all", name = "showdown", data = { cards = reveal } }

    -- Órdago first: an accepted órdago decides the whole game on its phase.
    for _, phase in ipairs({ "grande", "chica", "pares", "juego", "punto" }) do
        local r = hand.results[phase]
        if r and r.kind == "ordago" and not match.winner then
            local winnerSeat = bestSeat(match, phase, r.participants)
            winGameOutright(match, teamOf(winnerSeat), "órdago de " .. phase, events)
        end
    end

    if not match.winner then
        -- Grande / chica: paso → 1 piedra, accepted → the agreed amount.
        for _, phase in ipairs({ "grande", "chica" }) do
            local r = hand.results[phase]
            if r and (r.kind == "paso" or r.kind == "accepted") then
                local winnerSeat = bestSeat(match, phase, participantsFor(match, phase))
                local amount = (r.kind == "accepted") and r.amount or 1
                award(match, teamOf(winnerSeat), amount, phase, events)
                if match.winner then break end
            end
        end
    end

    if not match.winner then
        -- Pares: accepted stake to the phase winner, then per-hand bonuses to
        -- every member of the winning team who holds pares.
        local r = hand.results["pares"]
        if r and r.kind ~= "rejected" then
            local participants = participantsFor(match, "pares")
            if #participants > 0 then
                local winnerSeat = bestSeat(match, "pares", participants)
                local team = teamOf(winnerSeat)
                if r.kind == "accepted" then award(match, team, r.amount, "pares", events) end
                if not match.winner then
                    local bonus = 0
                    for _, seat in ipairs(participants) do
                        if teamOf(seat) == team then
                            bonus = bonus + paresBonus(hand.cards[seat], match.cfg)
                        end
                    end
                    award(match, team, bonus, "pares (mano)", events)
                end
            end
        elseif r and r.kind == "rejected" then
            -- Stake already scored; bonuses still go to the bettor's team hands.
            local bonus = 0
            for _, seat in ipairs(participantsFor(match, "pares")) do
                if teamOf(seat) == r.team then
                    bonus = bonus + paresBonus(hand.cards[seat], match.cfg)
                end
            end
            award(match, r.team, bonus, "pares (mano)", events)
        end
    end

    if not match.winner then
        -- Juego (or punto).
        local r = hand.results["juego"]
        local rp = hand.results["punto"]
        if r and r.kind ~= "rejected" then
            local participants = participantsFor(match, "juego")
            if #participants > 0 then
                local winnerSeat = bestSeat(match, "juego", participants)
                local team = teamOf(winnerSeat)
                if r.kind == "accepted" then award(match, team, r.amount, "juego", events) end
                if not match.winner then
                    local bonus = 0
                    for _, seat in ipairs(participants) do
                        if teamOf(seat) == team then
                            bonus = bonus + juegoBonus(hand.cards[seat], match.cfg)
                        end
                    end
                    award(match, team, bonus, "juego (mano)", events)
                end
            end
        elseif r and r.kind == "rejected" then
            local bonus = 0
            for _, seat in ipairs(participantsFor(match, "juego")) do
                if teamOf(seat) == r.team then
                    bonus = bonus + juegoBonus(hand.cards[seat], match.cfg)
                end
            end
            award(match, r.team, bonus, "juego (mano)", events)
        elseif rp then
            if rp.kind == "paso" or rp.kind == "accepted" then
                local winnerSeat = bestSeat(match, "punto", participantsFor(match, "punto"))
                local amount = (rp.kind == "accepted") and rp.amount or 1
                award(match, teamOf(winnerSeat), amount, "punto", events)
            end
            -- rejected punto stake already scored during betting
        end
    end

    events[#events + 1] = { to = "all", name = "hand_end", data = {
        awards = hand.awards,
        scores = { match.scores[1], match.scores[2] },
    } }
end

advanceStage = function(match, events)
    local hand = match.hand
    local stage = hand.stage
    if stage == "mus" or stage == "discard" then
        startPhase(match, "grande", events)
    elseif stage == "grande" then
        startPhase(match, "chica", events)
    elseif stage == "chica" then
        startPhase(match, "pares", events)
    elseif stage == "pares" then
        startPhase(match, "juego", events)
    elseif stage == "juego" or stage == "punto" then
        showdown(match, events)
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: whose input is awaited
-- ──────────────────────────────────────────────────────────────────────────────

-- Returns info about the awaited action(s): { stage, seats = {...}, options }
function MusEngine.turnInfo(match)
    local hand = match.hand
    if not hand or match.winner then return nil end
    if hand.stage == "mus" then
        return { stage = "mus", seats = { hand.order[hand.musIdx] },
                 options = { "mus", "no_mus" } }
    elseif hand.stage == "discard" then
        local seats = {}
        for _, seat in ipairs(hand.order) do
            if not hand.pendingDiscards[seat] then seats[#seats + 1] = seat end
        end
        return { stage = "discard", seats = seats, options = { "discard" } }
    elseif hand.betting then
        local bet = hand.betting
        local seat = bettingCurrentSeat(bet)
        local options
        if bet.mode == "open" then
            options = { "paso", "envido", "ordago" }
        else
            options = { "quiero", "no_quiero", "envido", "ordago" }
            if bet.isOrdago then options = { "quiero", "no_quiero" } end
        end
        return { stage = bet.phase, seats = { seat }, options = options,
                 proposed = bet.proposed, is_ordago = bet.isOrdago }
    end
    return nil
end

function MusEngine.pendingSeats(match)
    local info = MusEngine.turnInfo(match)
    return info and info.seats or {}
end

-- Reasonable action when a player times out.
function MusEngine.defaultAction(match, seat)
    local hand = match.hand
    if not hand then return nil end
    if hand.stage == "mus" then return { type = "no_mus" } end
    if hand.stage == "discard" then return { type = "discard", indices = { 1 } } end
    if hand.betting then
        if hand.betting.mode == "open" then return { type = "paso" } end
        return { type = "no_quiero" }
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: apply an action
-- ──────────────────────────────────────────────────────────────────────────────

local function isAwaited(match, seat)
    for _, s in ipairs(MusEngine.pendingSeats(match)) do
        if s == seat then return true end
    end
    return false
end

function MusEngine.apply(match, seat, action)
    if match.winner then return false, "game over" end
    local hand = match.hand
    if not hand then return false, "no hand in progress" end
    if type(action) ~= "table" or type(action.type) ~= "string" then
        return false, "malformed action"
    end
    if not isAwaited(match, seat) then return false, "not your turn" end

    local events = {}
    local stage = hand.stage

    -- ── mus round ────────────────────────────────────────────────────────────
    if stage == "mus" then
        if action.type == "mus" then
            events[#events + 1] = { to = "all", name = "mus_said", data = { seat = seat, mus = true } }
            hand.musIdx = hand.musIdx + 1
            if hand.musIdx > 4 then
                -- Everyone wants mus → discard round.
                hand.stage = "discard"
                hand.pendingDiscards = {}
                events[#events + 1] = { to = "all", name = "stage", data = { stage = "discard" } }
            end
        elseif action.type == "no_mus" then
            events[#events + 1] = { to = "all", name = "mus_said", data = { seat = seat, mus = false } }
            events[#events + 1] = { to = "all", name = "stage", data = { stage = "grande" } }
            startPhase(match, "grande", events)
            return true, events
        else
            return false, "expected mus/no_mus"
        end
        events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
        return true, events
    end

    -- ── discard round ────────────────────────────────────────────────────────
    if stage == "discard" then
        if action.type ~= "discard" then return false, "expected discard" end
        local indices = action.indices
        if type(indices) ~= "table" or #indices < 1 or #indices > 4 then
            return false, "discard 1-4 cards"
        end
        local seen = {}
        for _, idx in ipairs(indices) do
            idx = tonumber(idx)
            if not idx or idx < 1 or idx > 4 or seen[idx] then return false, "bad indices" end
            seen[idx] = true
        end
        hand.pendingDiscards[seat] = indices
        events[#events + 1] = { to = "all", name = "discard_chosen", data = { seat = seat, count = #indices } }

        -- When all four have chosen, execute the redraw.
        local allIn = true
        for _, s in ipairs(hand.order) do
            if not hand.pendingDiscards[s] then allIn = false break end
        end
        if allIn then
            for _, s in ipairs(hand.order) do
                local idxs = hand.pendingDiscards[s]
                table.sort(idxs, function(a, b) return a > b end)
                for _, idx in ipairs(idxs) do
                    table.insert(hand.discards, table.remove(hand.cards[s], idx))
                end
                for _ = 1, #idxs do
                    table.insert(hand.cards[s], draw(match))
                end
                events[#events + 1] = { to = s, name = "your_cards", data = { cards = hand.cards[s] } }
                events[#events + 1] = { to = "all", name = "redrew", data = { seat = s, count = #idxs } }
            end
            hand.pendingDiscards = nil
            hand.stage = "mus"
            hand.musIdx = 1
            events[#events + 1] = { to = "all", name = "stage", data = { stage = "mus" } }
        end
        events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
        return true, events
    end

    -- ── betting ──────────────────────────────────────────────────────────────
    local bet = hand.betting
    if not bet then return false, "no action expected" end
    local myTeam = teamOf(seat)

    local function announce(kind, amount)
        events[#events + 1] = { to = "all", name = "bet_action", data = {
            phase = bet.phase, seat = seat, action = kind, amount = amount,
            proposed = bet.proposed, is_ordago = bet.isOrdago } }
    end

    if bet.mode == "open" then
        if action.type == "paso" then
            announce("paso")
            bet.openIdx = bet.openIdx + 1
            if bet.openIdx > #bet.participants then
                return finishOpenPaso(match, bet, events)
            end
        elseif action.type == "envido" then
            local amount = math.max(2, math.floor(tonumber(action.amount) or 2))
            bet.proposed = amount
            bet.fallback = 1
            bet.proposerTeam = myTeam
            bet.mode = "responding"
            bet.responders = respondersFor(bet, myTeam)
            bet.respIdx = 1
            announce("envido", amount)
        elseif action.type == "ordago" then
            bet.isOrdago = true
            bet.fallback = 1
            bet.proposerTeam = myTeam
            bet.mode = "responding"
            bet.responders = respondersFor(bet, myTeam)
            bet.respIdx = 1
            announce("ordago")
        else
            return false, "expected paso/envido/ordago"
        end
    else -- responding
        if action.type == "quiero" then
            announce("quiero")
            if bet.isOrdago then
                local outcome = { kind = "ordago", participants = bet.participants }
                return true, finishAndCollect(match, outcome, events)
            end
            local outcome = { kind = "accepted", amount = bet.proposed }
            return true, finishAndCollect(match, outcome, events)
        elseif action.type == "no_quiero" then
            announce("no_quiero")
            bet.respIdx = bet.respIdx + 1
            if bet.respIdx > #bet.responders then
                local outcome = { kind = "rejected", amount = bet.fallback, team = bet.proposerTeam }
                return true, finishAndCollect(match, outcome, events)
            end
        elseif action.type == "envido" and not bet.isOrdago then
            -- Raise: implicitly accepts the previous stake.
            local raise = math.max(2, math.floor(tonumber(action.amount) or 2))
            bet.fallback = bet.proposed
            bet.proposed = bet.proposed + raise
            bet.proposerTeam = myTeam
            bet.responders = respondersFor(bet, myTeam)
            bet.respIdx = 1
            announce("envido", raise)
        elseif action.type == "ordago" and not bet.isOrdago then
            bet.isOrdago = true
            bet.fallback = bet.proposed
            bet.proposerTeam = myTeam
            bet.responders = respondersFor(bet, myTeam)
            bet.respIdx = 1
            announce("ordago")
        else
            return false, "unexpected response"
        end
    end

    events[#events + 1] = { to = "all", name = "turn", data = MusEngine.turnInfo(match) }
    return true, events
end

-- All participants passed in open mode.
function finishOpenPaso(match, bet, events)
    local outcome = { kind = "paso" }
    return true, finishAndCollect(match, outcome, events)
end

-- Shared tail for betting resolution.
function finishAndCollect(match, outcome, events)
    finishBetting(match, outcome, events)
    if not match.winner and match.hand.betting then
        -- next phase's turn event already emitted by startPhase
    end
    return events
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: hidden-information view
-- ──────────────────────────────────────────────────────────────────────────────

function MusEngine.viewFor(match, seat)
    local hand = match.hand
    local view = {
        cfg       = { reyes8 = match.cfg.reyes8, target = match.cfg.targetPiedras },
        scores    = { match.scores[1], match.scores[2] },
        mano_seat = match.manoSeat,
        hand_no   = match.handNo,
        winner    = match.winner,
        my_seat   = seat,
        my_team   = teamOf(seat),
    }
    if hand then
        view.stage    = hand.stage
        view.my_cards = hand.cards[seat]
        view.turn     = MusEngine.turnInfo(match)
        view.results  = hand.results
        if hand.revealed then
            view.all_cards = hand.cards
        end
        if hand.betting then
            view.proposed  = hand.betting.proposed
            view.is_ordago = hand.betting.isOrdago
        end
    end
    return view
end

-- Exposed for tests and bots.
MusEngine._internal = {
    strength = strength, points = points, teamOf = teamOf,
    paresOf = paresOf, pointsOf = pointsOf, hasJuego = hasJuego,
    cmpGrande = cmpGrande, cmpChica = cmpChica, cmpPares = cmpPares,
    cmpJuego = cmpJuego, cmpPunto = cmpPunto,
    paresBonus = paresBonus, juegoBonus = juegoBonus,
    newDeck = newDeck,
}

return MusEngine
