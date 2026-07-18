-- Heuristic mus bot. Decides an action for a seat from the engine's state.
-- Used to fill private tables, replace disconnected players, and for
-- practice games. Deliberately simple: phase strength scores 0..10 with
-- thresholds; a dash of randomness so bots aren't fully predictable.

local MusEngine = require("shared.mus_engine")
local I = MusEngine._internal

local Bot = {}

-- 0..10 how strong this hand is for a phase.
local function phaseScore(cards, phase, cfg)
    if phase == "grande" then
        local score = 0
        for _, c in ipairs(cards) do
            local s = I.strength(c.rank, cfg)
            if s >= 9 then score = score + 3        -- rey (or 3)
            elseif s >= 7 then score = score + 1 end -- sota/caballo
        end
        return math.min(score, 10)
    elseif phase == "chica" then
        local score = 0
        for _, c in ipairs(cards) do
            local s = I.strength(c.rank, cfg)
            if s <= 1 then score = score + 3        -- as (or 2)
            elseif s <= 3 then score = score + 1 end
        end
        return math.min(score, 10)
    elseif phase == "pares" then
        local p = I.paresOf(cards, cfg)
        if not p then return 0 end
        return math.min(p.class * 3 + (p.high >= 9 and 1 or 0), 10)
    elseif phase == "juego" then
        local pts = I.pointsOf(cards, cfg)
        if pts == 31 then return 10 end
        if pts == 32 then return 8 end
        if pts == 40 then return 7 end
        if pts >= 33 then return 6 end
        return 0
    elseif phase == "punto" then
        local pts = I.pointsOf(cards, cfg)
        if pts >= 30 then return 8 end
        if pts >= 27 then return 6 end
        if pts >= 24 then return 3 end
        return 1
    end
    return 0
end

-- Overall hand quality, for the mus decision.
local function overallScore(cards, cfg)
    local s = math.max(
        phaseScore(cards, "grande", cfg),
        phaseScore(cards, "chica", cfg),
        phaseScore(cards, "pares", cfg),
        phaseScore(cards, "juego", cfg))
    return s
end

function Bot.decide(match, seat)
    local hand = match.hand
    local cfg = match.cfg
    local cards = hand.cards[seat]
    local stage = hand.stage

    if stage == "mus" then
        -- Cut mus with a good hand; otherwise ask for cards.
        if overallScore(cards, cfg) >= 6 then return { type = "no_mus" } end
        return { type = "mus" }
    end

    if stage == "discard" then
        -- Keep figures, aces, and paired cards; discard the rest (1..4).
        local counts = {}
        for _, c in ipairs(cards) do
            local s = I.strength(c.rank, cfg)
            counts[s] = (counts[s] or 0) + 1
        end
        local indices = {}
        for i, c in ipairs(cards) do
            local s = I.strength(c.rank, cfg)
            local keep = s >= 9 or s <= 1 or counts[s] >= 2
            if not keep then indices[#indices + 1] = i end
        end
        if #indices == 0 then
            -- Everything looks good; the rules still require one discard.
            local worstIdx, worstVal = 1, math.huge
            for i, c in ipairs(cards) do
                local s = I.strength(c.rank, cfg)
                local v = math.min(10 - s, s)   -- distance from either extreme
                if counts[I.strength(c.rank, cfg)] < 2 and v < worstVal then
                    worstIdx, worstVal = i, v
                end
            end
            indices = { worstIdx }
        end
        return { type = "discard", indices = indices }
    end

    -- Betting.
    local bet = hand.betting
    if not bet then return { type = "paso" } end
    local score = phaseScore(cards, bet.phase, cfg)
    local roll = math.random()

    if bet.mode == "open" then
        if score >= 9 and roll < 0.15 then return { type = "ordago" } end
        if score >= 7 then return { type = "envido", amount = 2 } end
        if score >= 5 and roll < 0.35 then return { type = "envido", amount = 2 } end
        return { type = "paso" }
    else
        if bet.isOrdago then
            if score >= 9 then return { type = "quiero" } end
            return { type = "no_quiero" }
        end
        if score >= 9 and roll < 0.2 then return { type = "ordago" } end
        if score >= 8 and roll < 0.5 then return { type = "envido", amount = 2 } end
        if score >= 6 then return { type = "quiero" } end
        if score >= 5 and roll < 0.3 then return { type = "quiero" } end
        return { type = "no_quiero" }
    end
end

Bot.NAMES = { "Amarraco", "Piedras", "Hordago", "LaMano", "Postre", "Envite" }

function Bot.pickName(i)
    return "Bot " .. Bot.NAMES[((i - 1) % #Bot.NAMES) + 1]
end

return Bot
