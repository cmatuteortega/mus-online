-- Headless integration test for server/tables.lua: two mock humans + two
-- bots play a full game through the TableManager (no Love2D, no network).
-- Run from the repo root: lua tests/test_table_manager.lua

package.path = package.path .. ";./?.lua"
local json = require("lib.json")
local TM   = require("server.tables")

local failures = 0
local function check(cond, label)
    if cond then print("  OK   " .. label)
    else failures = failures + 1 print("  FAIL " .. label) end
end

math.randomseed(1234)

-- Mock peers capture every packet sent to them.
local function newMockPeer(name)
    return { name = name, inbox = {}, send = function(self, data)
        local ok, decoded = pcall(json.decode, data)
        if ok then table.insert(self.inbox, decoded) end
    end }
end

local peers = { newMockPeer("ana"), newMockPeer("bea") }
local logLines = {}

TM.init({
    encode  = function(eventName, data) return json.encode({ eventName, data }) end,
    pushLog = function(msg) table.insert(logLines, msg) end,
    db      = nil,
})

print("== table creation ==")
local t = TM.createTable({
    { peer = peers[1], connKey = 101, player_id = 1, username = "ana", trophies = 120, isBot = false },
    { peer = nil, connKey = nil, player_id = nil, username = "Bot A", trophies = 0, isBot = true },
    { peer = peers[2], connKey = 102, player_id = 2, username = "bea", trophies = 90, isBot = false },
    { peer = nil, connKey = nil, player_id = nil, username = "Bot B", trophies = 0, isBot = true },
}, { ranked = false })

local function lastEvent(peer, name)
    for i = #peer.inbox, 1, -1 do
        local m = peer.inbox[i]
        if m[1] == "game_event" and m[2].name == name then return m[2].data, i end
        if m[1] == name then return m[2], i end
    end
end

check(lastEvent(peers[1], "match_found") ~= nil, "ana got match_found")
local mf = lastEvent(peers[2], "match_found")
check(mf and mf.seat == 3 and mf.team == 1, "bea seated at 3 (team 1)")
check(mf and #mf.players == 4, "roster has 4 players")

print("== game starts after delay ==")
TM.update(2.1)
check(lastEvent(peers[1], "hand_start") ~= nil, "hand dealt")
local mine = lastEvent(peers[1], "your_cards")
check(mine and #mine.cards == 4, "ana got her 4 cards")

-- Count your_cards deliveries: each human must only ever get their own.
local function countEvents(peer, name)
    local n = 0
    for _, m in ipairs(peer.inbox) do
        if m[1] == "game_event" and m[2].name == name then n = n + 1 end
    end
    return n
end

print("== play a full game (humans auto-answer, bots think) ==")
local guard = 0
local finished = false
while guard < 20000 and not finished do
    guard = guard + 1
    TM.update(0.5)   -- advances bot clocks, next-hand pauses, etc.

    -- Answer any turn addressed to a human seat.
    for pi, seatNo in ipairs({ 1, 3 }) do
        local peer = peers[pi]
        local turn = lastEvent(peer, "turn")
        if turn and turn.seats then
            for _, s in ipairs(turn.seats) do
                if s == seatNo then
                    local action
                    if turn.stage == "mus" then
                        action = { type = math.random() < 0.3 and "mus" or "no_mus" }
                    elseif turn.stage == "discard" then
                        action = { type = "discard", indices = { 1, 2 } }
                    elseif turn.options and #turn.options > 0 and turn.options[1] == "quiero" then
                        action = { type = math.random() < 0.5 and "quiero" or "no_quiero" }
                    else
                        local r = math.random()
                        action = r < 0.2 and { type = "envido", amount = 2 } or { type = "paso" }
                    end
                    TM.handleIntent(seatNo == 1 and 101 or 102, { action = action })
                end
            end
        end
    end

    if lastEvent(peers[1], "game_end") then finished = true end
end
check(finished, "game reached game_end (in " .. guard .. " ticks)")
check(countEvents(peers[1], "your_cards") > 0, "cards kept flowing to ana")

-- Hidden information: ana's your_cards must always equal what the engine
-- would show HER — spot-check: every your_cards has exactly 4 cards and we
-- never received one addressed to another seat (your_cards carries no seat,
-- it is only ever sent to its owner by construction; assert both humans got
-- a similar count rather than 4x as many).
local ca, cb = countEvents(peers[1], "your_cards"), countEvents(peers[2], "your_cards")
check(math.abs(ca - cb) <= 2, "per-seat private deliveries balanced (" .. ca .. "/" .. cb .. ")")

print("== disconnect → grace → bot takeover ==")
local t2peers = { newMockPeer("carl"), newMockPeer("dana") }
TM.createTable({
    { peer = t2peers[1], connKey = 201, player_id = 11, username = "carl", trophies = 0, isBot = false },
    { peer = nil, connKey = nil, player_id = nil, username = "Bot A", trophies = 0, isBot = true },
    { peer = t2peers[2], connKey = 202, player_id = 12, username = "dana", trophies = 0, isBot = false },
    { peer = nil, connKey = nil, player_id = nil, username = "Bot B", trophies = 0, isBot = true },
}, { ranked = false })
TM.update(2.1)
TM.handleDisconnect(201)
check(lastEvent(t2peers[2], "player_disconnected") ~= nil, "table notified of disconnect")

-- Reconnect within grace: seat restored with snapshot.
local back = newMockPeer("carl2")
check(TM.tryReattach(11, back, 301), "reattach accepted")
local snap = lastEvent(back, "state_snapshot")
check(snap and snap.seat == 1 and snap.view and snap.view.my_cards, "snapshot includes own cards")

-- Disconnect again and let the grace expire → bot takeover.
TM.handleDisconnect(301)
for _ = 1, 100 do TM.update(1.0) end
local rep = lastEvent(t2peers[2], "seat_replaced")
check(rep ~= nil and rep.seat == 1, "grace expired: seat replaced by bot")

print("")
if failures > 0 then
    print(failures .. " TEST(S) FAILED")
    os.exit(1)
else
    print("ALL TESTS PASSED")
end
