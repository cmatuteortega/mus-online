-- Table manager: 4-player mus tables hosted on the server.
-- Owns the authoritative MusEngine match per table, routes player intents,
-- runs turn timeouts, drives bots, and handles disconnect/reconnect.
--
-- Seats/teams: partners across — team 1 = seats {1,3}, team 2 = seats {2,4}.

local MusEngine = require("shared.mus_engine")
local Bot       = require("shared.mus_bot")

local TableManager = {}

local START_DELAY   = 2.0    -- seconds between match_found and the first deal
local TURN_TIMEOUT  = 25.0   -- seconds before a default action is forced
local BOT_DELAY     = 1.4    -- seconds a bot "thinks" before acting
local GRACE_PERIOD  = 45.0   -- seconds a disconnected player may reconnect
local CLEANUP_DELAY = 30.0   -- seconds a finished table lingers (for late clients)

local deps           -- { encode, pushLog, db }
local tables = {}    -- id → table
local byConn = {}    -- connKey → { tableId, seat }
local byPlayer = {}  -- player_id → { tableId, seat }
local nextId = 1

function TableManager.init(d) deps = d end

local function teamOf(seat) return (seat % 2 == 1) and 1 or 2 end

-- ── messaging ────────────────────────────────────────────────────────────────

local function sendTo(t, seat, name, data)
    local s = t.seats[seat]
    if s and s.peer and not s.isBot and s.connected then
        pcall(function() s.peer:send(deps.encode("game_event", { name = name, data = data })) end)
    end
end

local function broadcast(t, name, data, exceptSeat)
    for seat = 1, 4 do
        if seat ~= exceptSeat then sendTo(t, seat, name, data) end
    end
end

local function dispatch(t, events)
    for _, e in ipairs(events or {}) do
        if e.to == "all" then broadcast(t, e.name, e.data)
        else sendTo(t, e.to, e.name, e.data) end
    end
end

local function roster(t)
    local out = {}
    for seat = 1, 4 do
        local s = t.seats[seat]
        out[#out + 1] = {
            seat = seat, team = teamOf(seat),
            username = s.username, trophies = s.trophies,
            is_bot = s.isBot or false, connected = s.connected or false,
        }
    end
    return out
end

-- ── timers helpers ───────────────────────────────────────────────────────────

local function resetTurnClock(t)
    t.turnClock = TURN_TIMEOUT
    t.botClock  = BOT_DELAY
end

local function afterEngineStep(t)
    resetTurnClock(t)
    if t.match and t.match.winner then
        TableManager._finishGame(t)
    elseif t.match and not t.match.hand.betting and t.match.hand.stage == "showdown" then
        -- Hand over: deal the next one after a pause.
        t.nextHandClock = 6.0
    end
end

-- ── game lifecycle ───────────────────────────────────────────────────────────

-- players: array of exactly 4 entries { peer|nil, connKey|nil, player_id|nil,
-- username, trophies, isBot }. Ordered by seat (1..4).
function TableManager.createTable(players, opts)
    opts = opts or {}
    local t = {
        id = nextId, seats = {}, match = nil,
        startClock = START_DELAY, ranked = opts.ranked or false,
        finished = false,
    }
    nextId = nextId + 1
    for seat = 1, 4 do
        local p = players[seat]
        t.seats[seat] = {
            peer = p.peer, connKey = p.connKey, player_id = p.player_id,
            username = p.username, trophies = p.trophies or 0,
            isBot = p.isBot or false, connected = (not p.isBot) and p.peer ~= nil,
            graceClock = nil,
        }
        if p.connKey then byConn[p.connKey] = { tableId = t.id, seat = seat } end
        if p.player_id then byPlayer[p.player_id] = { tableId = t.id, seat = seat } end
    end
    tables[t.id] = t

    local list = roster(t)
    for seat = 1, 4 do
        local s = t.seats[seat]
        if s.peer and not s.isBot then
            pcall(function() s.peer:send(deps.encode("match_found", {
                seat = seat, team = teamOf(seat),
                my_trophies = s.trophies, ranked = t.ranked,
                players = list,
            })) end)
        end
    end
    deps.pushLog("Table " .. t.id .. " created (" .. (t.ranked and "ranked" or "friendly") .. ")")
    return t
end

function TableManager._start(t)
    t.match = MusEngine.newMatch({}, os.time() * 131 + t.id)
    local events = MusEngine.startHand(t.match)
    dispatch(t, events)
    afterEngineStep(t)
end

function TableManager._finishGame(t)
    if t.finished then return end
    t.finished = true
    t.cleanupClock = CLEANUP_DELAY
    local winnerTeam = t.match.winner
    deps.pushLog("Table " .. t.id .. " finished — team " .. tostring(winnerTeam) .. " wins")

    if t.ranked and deps.db then
        for seat = 1, 4 do
            local s = t.seats[seat]
            if s.player_id then
                local won = teamOf(seat) == winnerTeam
                deps.db:updateTrophies(s.player_id, won and 20 or -15)
                local gold = deps.db:updateGold(s.player_id, won and 10 or 5)
                local xp   = deps.db:updateXP(s.player_id, won and 10 or 7)
                local gems = deps.db:getGems(s.player_id)
                sendTo(t, seat, "rewards", { won = won,
                    trophy_delta = won and 20 or -15,
                    gold = gold, gems = gems, xp = xp.xp, level = xp.level })
                if s.peer and s.connected then
                    pcall(function() s.peer:send(deps.encode("currency_update", {
                        gold = gold, gems = gems, xp = xp.xp, level = xp.level, unlocks = xp.unlocks })) end)
                end
            end
        end
    end
end

local function destroyTable(t)
    for seat = 1, 4 do
        local s = t.seats[seat]
        if s.connKey and byConn[s.connKey] and byConn[s.connKey].tableId == t.id then
            byConn[s.connKey] = nil
        end
        if s.player_id and byPlayer[s.player_id] and byPlayer[s.player_id].tableId == t.id then
            byPlayer[s.player_id] = nil
        end
    end
    tables[t.id] = nil
end

-- ── intents ──────────────────────────────────────────────────────────────────

function TableManager.handleIntent(ck, msgData)
    local ref = byConn[ck]
    if not ref then return end
    local t = tables[ref.tableId]
    if not t or not t.match or t.finished then return end
    local action = msgData and msgData.action
    if type(action) ~= "table" then return end

    local ok, res = MusEngine.apply(t.match, ref.seat, action)
    if not ok then
        sendTo(t, ref.seat, "action_rejected", { reason = res })
        return
    end
    dispatch(t, res)
    afterEngineStep(t)
end

-- Emotes / señas: thin relay, never touches the engine.
function TableManager.handleEmote(ck, msgData)
    local ref = byConn[ck]
    if not ref then return end
    local t = tables[ref.tableId]
    if not t then return end
    broadcast(t, "emote", { seat = ref.seat, emote = tostring(msgData.emote or "") }, ref.seat)
end

-- Voluntary leave: seat becomes a bot; leaving a ranked game costs trophies.
function TableManager.leaveTable(ck)
    local ref = byConn[ck]
    if not ref then return end
    local t = tables[ref.tableId]
    if not t then return end
    local s = t.seats[ref.seat]
    deps.pushLog("Table " .. t.id .. ": " .. tostring(s.username) .. " left seat " .. ref.seat)
    if t.ranked and not t.finished and s.player_id and deps.db then
        deps.db:updateTrophies(s.player_id, -15)
    end
    byConn[ck] = nil
    if s.player_id then byPlayer[s.player_id] = nil end
    s.peer, s.connKey, s.player_id = nil, nil, nil
    s.isBot, s.connected, s.graceClock = true, false, nil
    s.username = s.username .. " (bot)"
    broadcast(t, "seat_replaced", { seat = ref.seat, by_bot = true, players = roster(t) })
end

-- ── disconnect / reconnect ───────────────────────────────────────────────────

function TableManager.handleDisconnect(ck)
    local ref = byConn[ck]
    if not ref then return end
    local t = tables[ref.tableId]
    byConn[ck] = nil
    if not t or t.finished then return end
    local s = t.seats[ref.seat]
    s.connected = false
    s.peer = nil
    s.connKey = nil
    s.graceClock = GRACE_PERIOD
    deps.pushLog("Table " .. t.id .. ": seat " .. ref.seat .. " disconnected (grace)")
    broadcast(t, "player_disconnected", { seat = ref.seat })
end

-- Called after a successful (re)auth. Returns true if the player was seated
-- at a live table and has been re-attached.
function TableManager.tryReattach(playerId, peer, ck)
    local ref = byPlayer[playerId]
    if not ref then return false end
    local t = tables[ref.tableId]
    if not t or t.finished then return false end
    local s = t.seats[ref.seat]
    if s.isBot then return false end   -- grace expired; seat already botted
    s.peer, s.connKey = peer, ck
    s.connected, s.graceClock = true, nil
    byConn[ck] = { tableId = t.id, seat = ref.seat }
    broadcast(t, "player_reconnected", { seat = ref.seat }, ref.seat)
    local snapshot = t.match and MusEngine.viewFor(t.match, ref.seat) or nil
    sendTo(t, ref.seat, "state_snapshot", {
        players = roster(t), seat = ref.seat, team = teamOf(ref.seat),
        ranked = t.ranked, view = snapshot,
    })
    deps.pushLog("Table " .. t.id .. ": seat " .. ref.seat .. " reconnected")
    return true
end

-- ── update loop ──────────────────────────────────────────────────────────────

local function pendingInfo(t)
    if not t.match or t.match.winner then return nil end
    local seats = MusEngine.pendingSeats(t.match)
    if #seats == 0 then return nil end
    return seats
end

function TableManager.update(dt)
    for _, t in pairs(tables) do
        if t.startClock then
            t.startClock = t.startClock - dt
            if t.startClock <= 0 then
                t.startClock = nil
                TableManager._start(t)
            end
        elseif t.finished then
            t.cleanupClock = (t.cleanupClock or CLEANUP_DELAY) - dt
            if t.cleanupClock <= 0 then destroyTable(t) end
        elseif t.nextHandClock then
            t.nextHandClock = t.nextHandClock - dt
            if t.nextHandClock <= 0 then
                t.nextHandClock = nil
                dispatch(t, MusEngine.startHand(t.match))
                afterEngineStep(t)
            end
        elseif t.match then
            local seats = pendingInfo(t)
            if seats then
                -- Grace timers for disconnected humans.
                for seat = 1, 4 do
                    local s = t.seats[seat]
                    if s.graceClock then
                        s.graceClock = s.graceClock - dt
                        if s.graceClock <= 0 then
                            s.graceClock = nil
                            if s.player_id then byPlayer[s.player_id] = nil end
                            s.player_id, s.isBot = nil, true
                            s.username = s.username .. " (bot)"
                            broadcast(t, "seat_replaced", { seat = seat, by_bot = true, players = roster(t) })
                        end
                    end
                end

                -- Bots (and botted seats) act after a short delay.
                local firstPending = seats[1]
                local actor = t.seats[firstPending]
                if actor.isBot or not actor.connected then
                    t.botClock = (t.botClock or BOT_DELAY) - dt
                    if t.botClock <= 0 then
                        local action = actor.isBot
                            and Bot.decide(t.match, firstPending)
                            or MusEngine.defaultAction(t.match, firstPending)
                        local ok, res = MusEngine.apply(t.match, firstPending, action)
                        if ok then dispatch(t, res) end
                        afterEngineStep(t)
                    end
                else
                    -- Human turn: enforce the timeout.
                    t.turnClock = (t.turnClock or TURN_TIMEOUT) - dt
                    if t.turnClock <= 0 then
                        local action = MusEngine.defaultAction(t.match, firstPending)
                        local ok, res = MusEngine.apply(t.match, firstPending, action)
                        if ok then dispatch(t, res) end
                        sendTo(t, firstPending, "timed_out", {})
                        afterEngineStep(t)
                    end
                end
            end
        end
    end
end

function TableManager.count()
    local n = 0
    for _ in pairs(tables) do n = n + 1 end
    return n
end

return TableManager
