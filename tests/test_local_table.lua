-- Headless test for the sandbox driver (src/local_table.lua): the player at
-- seat 1 plus 3 bots play a full offline game.
-- Run from the repo root: lua tests/test_local_table.lua

package.path = package.path .. ";./?.lua"
local LocalTable = require("src.local_table")

local failures = 0
local function check(cond, label)
    if cond then print("  OK   " .. label)
    else failures = failures + 1 print("  FAIL " .. label) end
end

math.randomseed(99)

local events = {}
local lastTurn = nil
local myCards = nil
local gameEnd = nil

local lt = LocalTable.new(function(name, data)
    events[#events + 1] = name
    if name == "turn" then lastTurn = data end
    if name == "your_cards" then myCards = data.cards end
    if name == "game_end" then gameEnd = data end
end)

print("== sandbox roster ==")
local roster = LocalTable.roster()
check(#roster == 4 and not roster[1].is_bot and roster[2].is_bot, "seat 1 human, rest bots")

print("== full offline game ==")
lt:start()
check(myCards and #myCards == 4, "player got 4 cards")

local guard = 0
while not gameEnd and guard < 30000 do
    guard = guard + 1
    lt:update(0.4)
    if lastTurn and lastTurn.seats then
        for _, s in ipairs(lastTurn.seats) do
            if s == 1 then
                local action
                if lastTurn.stage == "mus" then
                    action = { type = math.random() < 0.3 and "mus" or "no_mus" }
                elseif lastTurn.stage == "discard" then
                    action = { type = "discard", indices = { 1 } }
                elseif lastTurn.options and lastTurn.options[1] == "quiero" then
                    action = { type = math.random() < 0.5 and "quiero" or "no_quiero" }
                else
                    action = math.random() < 0.2 and { type = "envido", amount = 2 } or { type = "paso" }
                end
                lastTurn = nil
                lt:send(action)
                break
            end
        end
    end
end
check(gameEnd ~= nil, "offline game reached game_end (in " .. guard .. " ticks)")
check(lt.done, "local table marked done")

print("")
if failures > 0 then
    print(failures .. " TEST(S) FAILED")
    os.exit(1)
else
    print("ALL TESTS PASSED")
end
