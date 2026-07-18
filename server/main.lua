-- Mus Online – Authoritative Game Server with Authentication & Matchmaking
-- Run with: love server/ (from the repo root directory)
-- Clients authenticate and queue; the server forms 4-player tables (2v2),
-- hosts the authoritative mus engine per table (server/tables.lua), and
-- routes validated intents. Clients never see each other's cards.

local enet = require("enet")

-- Set up path for repo-root modules (shared/, server/, lib/)
package.path = package.path .. ';../?.lua'

local Database     = require("server.database")
local TableManager = require("server.tables")
local Bot          = require("server.bot")

local PORT    = 12346
local MAX_CONNECTIONS = 64

local host    = nil
local db      = nil
local queue        = {}    -- matchmaking queue: {peer, player_id, username, trophies, queue_time}
local sessions     = {}    -- keyed by connKey (integer): {player_id, username, token}
local privateQueue = {}    -- private tables: room_key → { players = { {peer, player_id, username, trophies} ... } }

-- Per-connection unique IDs — avoids session key collision when ENet reuses peer slots
local connCounter    = 0
local connKeys       = {}   -- tostring(peer) → unique integer per connection
local peerByPlayerId = {}   -- player_id → peer (for evicting old connections on re-login)

local function connKey(peer)
    return connKeys[tostring(peer)]
end

-- Forward declaration (defined fully after handleConnect/processMatchmaking)
local handleDisconnect
local log     = {}
local logLimit = 18

local logFile = nil

local function pushLog(msg)
    table.insert(log, msg)
    if #log > logLimit then table.remove(log, 1) end
    print(msg)

    -- Also write to file for debugging
    if logFile then
        logFile:write(os.date("%H:%M:%S") .. " - " .. msg .. "\n")
        logFile:flush()
    end
end

-- Build a sock.lua-compatible JSON packet: ["eventName", data]
-- Requires lib/json.lua to be available when running from the project root.
-- Falls back to a hand-rolled encoder for simple tables if json is not loaded.
local json
local ok, mod = pcall(require, "lib.json")
if ok then json = mod end

local function encode(eventName, data)
    if json then
        return json.encode({eventName, data})
    end
    -- Minimal fallback encoder (numbers, strings, booleans only at top level)
    local function val(v)
        local t = type(v)
        if t == "number"  then return tostring(v) end
        if t == "boolean" then return tostring(v) end
        if t == "string"  then return '"' .. v:gsub('"', '\\"') .. '"' end
        if t == "table" then
            local arr, obj = {}, {}
            for k, vv in pairs(v) do
                if type(k) == "number" then
                    arr[k] = val(vv)
                else
                    table.insert(obj, '"'..k..'":'..val(vv))
                end
            end
            if #arr > 0 then
                return "["..table.concat(arr, ",").."]"
            else
                return "{"..table.concat(obj, ",").."}"
            end
        end
        return "null"
    end
    return "["..val(eventName)..","..val(data).."]"
end

-- Matchmaking: allowed trophy range grows the longer a player waits.
local function allowedRange(player)
    local waitTime = love.timer.getTime() - player.queue_time
    return math.min(100 + math.floor(waitTime / 5) * 50, 500)
end

-- Find 4 mutually-compatible players (anchor = longest waiting first).
local function findGroup()
    for i, anchor in ipairs(queue) do
        local range = allowedRange(anchor)
        local group = { i }
        for j, other in ipairs(queue) do
            if j ~= i and math.abs(anchor.trophies - other.trophies) <= range then
                group[#group + 1] = j
                if #group == 4 then return group end
            end
        end
    end
    return nil
end

-- Seat assignment balances teams: sort by trophies, best pairs with worst
-- (team 1 = seats 1,3 · team 2 = seats 2,4).
local function seatPlayers(entries)
    table.sort(entries, function(a, b) return a.trophies > b.trophies end)
    return { entries[1], entries[2], entries[4], entries[3] }
end

local function toSeatEntry(q)
    return { peer = q.peer, connKey = connKey(q.peer), player_id = q.player_id,
             username = q.username, trophies = q.trophies, isBot = false }
end

-- Form as many 4-player tables as the queue allows.
local function processMatchmaking()
    while #queue >= 4 do
        local group = findGroup()
        if not group then return end
        table.sort(group, function(a, b) return a > b end)   -- remove high→low
        local entries = {}
        for _, idx in ipairs(group) do
            entries[#entries + 1] = toSeatEntry(table.remove(queue, idx))
        end
        local seated = seatPlayers(entries)
        TableManager.createTable(seated, { ranked = true })
        pushLog("Match: " .. seated[1].username .. "+" .. seated[3].username ..
                " vs " .. seated[2].username .. "+" .. seated[4].username)
    end
end

local function evictStaleAtAddress(raw)
    local staleKey = connKeys[raw]
    if not staleKey then return end

    -- Stale session (peer slot reused without disconnect event firing)
    local s = sessions[staleKey]
    if s then
        peerByPlayerId[s.player_id] = nil
        pushLog("Evicting stale session (peer reuse): " .. s.username)
        sessions[staleKey] = nil
    end

    -- Remove stale queue entry
    for i = #queue, 1, -1 do
        if connKeys[tostring(queue[i].peer)] == staleKey then
            table.remove(queue, i)
        end
    end

    -- Detach from any live table (starts the reconnect grace timer)
    TableManager.handleDisconnect(staleKey)

    connKeys[raw] = nil
end

local function handleConnect(peer)
    local raw = tostring(peer)
    evictStaleAtAddress(raw)          -- clear any stale session at this peer slot
    connCounter = connCounter + 1
    connKeys[raw] = connCounter
    pushLog("Client connected: " .. raw .. " (conn=" .. connCounter .. ")")
end

-- Evict an existing live connection for player_id (called on re-login)
local function evictPlayerSession(playerId, incomingPeer)
    local oldPeer = peerByPlayerId[playerId]
    if oldPeer and oldPeer ~= incomingPeer then
        pcall(function() oldPeer:send(encode("forced_logout", {reason = "Logged in from another device"})) end)
        handleDisconnect(oldPeer)
        pcall(function() oldPeer:reset() end)
    end
end

local function handleMessage(peer, eventName, msgData)
    local ck = connKey(peer)
    if not ck then return end   -- peer has no connection ID (shouldn't happen)

    -- ── Authentication ──────────────────────────────────────────────────────

    if eventName == "login" then
        local username = msgData.username
        local password = msgData.password
        local deviceId = msgData.device_id or ""

        local player, err = db:loginPlayer(username, password)

        if player then
            -- Invalidate all old DB tokens for this player, then create a fresh one
            db:deletePlayerSessions(player.id)
            -- Kick any existing live connection for this player
            evictPlayerSession(player.id, peer)

            local token = db:createSession(player.id, deviceId)
            sessions[ck] = {
                player_id = player.id,
                username  = player.username,
                token     = token
            }
            peerByPlayerId[player.id] = peer

            -- Migrate unlocks for existing players if needed
            local unlocks = player.unlocks
            if not unlocks then
                unlocks = db:migrateUnlocks(player.id)
            end

            peer:send(encode("login_success", {
                player_id         = player.id,
                username          = player.username,
                trophies          = player.trophies,
                coins             = player.coins,
                gold              = player.gold,
                gems              = player.gems,
                xp                = player.xp,
                level             = player.level,
                active_deck_index = player.activeDeckIndex,
                decks             = player.decks,
                token             = token,
                unlocks           = unlocks,
                has_email_backup  = player.hasEmail or false
            }))
            pushLog("Login: " .. username)
        else
            peer:send(encode("login_failed", {reason = err or "Invalid credentials"}))
            pushLog("Failed login: " .. tostring(username))
        end

    elseif eventName == "register" then
        local username = msgData.username
        local password = msgData.password

        local player, err = db:registerPlayer(username, password)

        if player then
            peer:send(encode("register_success", {
                player_id = player.id,
                username  = player.username
            }))
            pushLog("Registration: " .. username)
        else
            peer:send(encode("register_failed", {reason = err or "Registration failed"}))
            pushLog("Failed registration: " .. tostring(username))
        end

    elseif eventName == "register_device" then
        local username = msgData.username
        local deviceId = msgData.device_id or ""

        -- Idempotent per device: if a profile already exists, reuse it
        local player = db:findPlayerByDevice(deviceId)
        local created = false
        if not player then
            local err
            player, err = db:registerPlayerByDevice(username, deviceId)
            if not player then
                peer:send(encode("register_failed", {reason = err or "Registration failed"}))
                pushLog("Failed device registration: " .. tostring(username))
                return
            end
            created = true
        end

        db:deletePlayerSessions(player.id)
        evictPlayerSession(player.id, peer)

        local token = db:createSession(player.id, deviceId)
        sessions[ck] = {
            player_id = player.id,
            username  = player.username,
            token     = token
        }
        peerByPlayerId[player.id] = peer

        local unlocks = player.unlocks
        if not unlocks then
            unlocks = db:migrateUnlocks(player.id)
        end

        peer:send(encode("login_success", {
            player_id         = player.id,
            username          = player.username,
            trophies          = player.trophies,
            coins             = player.coins,
            gold              = player.gold,
            gems              = player.gems,
            xp                = player.xp,
            level             = player.level,
            active_deck_index = player.activeDeckIndex,
            decks             = player.decks,
            token             = token,
            unlocks           = unlocks,
            has_email_backup  = player.hasEmail or false
        }))
        pushLog((created and "Device register: " or "Device reuse: ") .. player.username)

    elseif eventName == "login_with_device" then
        local deviceId = msgData.device_id or ""

        local player = db:findPlayerByDevice(deviceId)
        pushLog("[DEBUG] login_with_device player=" .. tostring(player and player.username) .. " hasEmail=" .. tostring(player and player.hasEmail))
        if not player then
            peer:send(encode("login_failed", {reason = "no_device_profile"}))
            return
        end

        db:deletePlayerSessions(player.id)
        evictPlayerSession(player.id, peer)

        local token = db:createSession(player.id, deviceId)
        sessions[ck] = {
            player_id = player.id,
            username  = player.username,
            token     = token
        }
        peerByPlayerId[player.id] = peer

        local unlocks = player.unlocks
        if not unlocks then
            unlocks = db:migrateUnlocks(player.id)
        end

        peer:send(encode("login_success", {
            player_id         = player.id,
            username          = player.username,
            trophies          = player.trophies,
            coins             = player.coins,
            gold              = player.gold,
            gems              = player.gems,
            xp                = player.xp,
            level             = player.level,
            active_deck_index = player.activeDeckIndex,
            decks             = player.decks,
            token             = token,
            unlocks           = unlocks,
            has_email_backup  = player.hasEmail or false
        }))
        pushLog("Device login: " .. player.username)

        -- App restart during a game: put them straight back at their table.
        TableManager.tryReattach(player.id, peer, ck)

    elseif eventName == "queue_join" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local player = db:getPlayer(session.player_id)
        if not player then
            peer:send(encode("error", {reason = "Player not found"}))
            return
        end

        -- Remove any stale queue entries for this player_id (rapid reconnect guard)
        for i = #queue, 1, -1 do
            if queue[i].player_id == player.id then
                pushLog("Removed duplicate queue entry: " .. player.username)
                table.remove(queue, i)
            end
        end

        table.insert(queue, {
            peer       = peer,
            player_id  = player.id,
            username   = player.username,
            trophies   = player.trophies,
            queue_time = love.timer.getTime()
        })

        peer:send(encode("queue_joined", {}))
        pushLog("Queue join: " .. player.username .. " (" .. player.trophies .. " trophies)")

    elseif eventName == "queue_leave" then
        for i, entry in ipairs(queue) do
            if entry.peer == peer then
                table.remove(queue, i)
                peer:send(encode("queue_left", {}))
                pushLog("Queue leave: " .. entry.username)
                break
            end
        end

    elseif eventName == "get_leaderboard" then
        local top = db:getLeaderboard(5)
        peer:send(encode("leaderboard_data", { players = top }))

    elseif eventName == "private_queue_join" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end
        local player = db:getPlayer(session.player_id)
        if not player then
            peer:send(encode("error", {reason = "Player not found"}))
            return
        end
        local key = msgData.room_key
        if not key or key == "" then
            peer:send(encode("error", {reason = "Invalid room key"}))
            return
        end
        -- Remove any existing private queue entry for this player
        for k, room in pairs(privateQueue) do
            for i = #room.players, 1, -1 do
                if room.players[i].player_id == player.id then table.remove(room.players, i) end
            end
            if #room.players == 0 then privateQueue[k] = nil end
        end

        privateQueue[key] = privateQueue[key] or { players = {} }
        local room = privateQueue[key]
        if #room.players >= 4 then
            peer:send(encode("error", {reason = "Room full"}))
            return
        end
        table.insert(room.players, { peer = peer, player_id = player.id,
                                     username = player.username, trophies = player.trophies })
        pushLog("Private queue: " .. player.username .. " on key=" .. key .. " (" .. #room.players .. "/4)")

        -- Everyone in the room sees the lobby fill up.
        local names = {}
        for _, p in ipairs(room.players) do names[#names + 1] = { username = p.username, trophies = p.trophies } end
        for i, p in ipairs(room.players) do
            pcall(function() p.peer:send(encode("private_lobby_update", {
                players = names, count = #room.players, is_host = (i == 1) })) end)
        end

        if #room.players == 4 then
            privateQueue[key] = nil
            local entries = {}
            for _, p in ipairs(room.players) do
                entries[#entries + 1] = { peer = p.peer, connKey = connKey(p.peer), player_id = p.player_id,
                                          username = p.username, trophies = p.trophies, isBot = false }
            end
            TableManager.createTable(entries, { ranked = false })
            pushLog("Private table started (key=" .. key .. ")")
        end

    elseif eventName == "private_start_bots" then
        -- Host starts the private table early; empty seats become bots.
        local session = sessions[ck]
        if not session then return end
        for key, room in pairs(privateQueue) do
            if room.players[1] and room.players[1].player_id == session.player_id then
                privateQueue[key] = nil
                local entries = {}
                for _, p in ipairs(room.players) do
                    entries[#entries + 1] = { peer = p.peer, connKey = connKey(p.peer), player_id = p.player_id,
                                              username = p.username, trophies = p.trophies, isBot = false }
                end
                for i = #entries + 1, 4 do
                    entries[i] = { username = Bot.pickName(i), trophies = 0, isBot = true }
                end
                TableManager.createTable(entries, { ranked = false })
                pushLog("Private table started with bots (key=" .. key .. ")")
                return
            end
        end

    elseif eventName == "private_queue_leave" then
        for k, room in pairs(privateQueue) do
            for i = #room.players, 1, -1 do
                if room.players[i].peer == peer then
                    pushLog("Private queue leave: " .. room.players[i].username)
                    table.remove(room.players, i)
                    peer:send(encode("queue_left", {}))
                end
            end
            if #room.players == 0 then
                privateQueue[k] = nil
            else
                local names = {}
                for _, p in ipairs(room.players) do names[#names + 1] = { username = p.username, trophies = p.trophies } end
                for i, p in ipairs(room.players) do
                    pcall(function() p.peer:send(encode("private_lobby_update", {
                        players = names, count = #room.players, is_host = (i == 1) })) end)
                end
            end
        end

    elseif eventName == "update_deck_slot" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local deckIndex = msgData.deck_index
        local deckData = msgData.deck_data

        if not deckIndex or not deckData then
            peer:send(encode("error", {reason = "Invalid deck update"}))
            return
        end

        local success, err = db:updateDeckSlot(session.player_id, deckIndex, deckData)
        if success then
            peer:send(encode("deck_updated", {deck_index = deckIndex}))
            pushLog("Deck " .. deckIndex .. " updated: " .. session.username)
        else
            peer:send(encode("error", {reason = err or "Failed to update deck"}))
        end

    elseif eventName == "update_active_deck" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local deckIndex = msgData.deck_index

        db:updateActiveDeck(session.player_id, deckIndex)
        peer:send(encode("active_deck_updated", {deck_index = deckIndex}))
        pushLog("Active deck set to " .. tostring(deckIndex) .. ": " .. session.username)

    elseif eventName == "sync_decks" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local activeDeckIndex = msgData.active_deck_index
        local decks = msgData.decks

        if not decks or #decks ~= 5 then
            peer:send(encode("error", {reason = "Invalid deck data"}))
            return
        end

        local success, err = db:updateAllDecks(session.player_id, activeDeckIndex, decks)
        if success then
            peer:send(encode("decks_synced", {}))
            pushLog("All decks synced: " .. session.username)
        else
            peer:send(encode("error", {reason = err or "Failed to sync decks"}))
        end

    elseif eventName == "award_card" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end
        local unitType = msgData.unit
        if not unitType or type(unitType) ~= "string" then
            peer:send(encode("error", {reason = "Missing unit type"}))
            return
        end
        local cost = tonumber(msgData.cost) or 0
        local newGold
        if cost > 0 then
            newGold = db:updateGold(session.player_id, -cost)
        end
        local unlocks = db:awardCard(session.player_id, unitType)
        if unlocks then
            peer:send(encode("card_awarded", { unlocks = unlocks, gold = newGold }))
            pushLog("Card awarded (" .. unitType .. ", cost " .. cost .. "g): " .. session.username)
        else
            peer:send(encode("error", {reason = "Failed to award card"}))
        end

    elseif eventName == "get_online_count" then
        local count = 0
        for _ in pairs(sessions) do count = count + 1 end
        peer:send(encode("online_count", {count = count}))

    -- NOTE: the old client-reported "match_result" is gone — game results are
    -- decided by the server-side engine (TableManager awards trophies/rewards).

    elseif eventName == "reconnect_with_token" then
        local token    = msgData.token
        local deviceId = msgData.device_id or ""
        if not token or not db then
            peer:send(encode("login_failed", {reason = "No token"}))
            return
        end
        local player = db:validateSession(token, deviceId)
        pushLog("[DEBUG] reconnect_with_token player=" .. tostring(player and player.username) .. " hasEmail=" .. tostring(player and player.hasEmail))
        if player then
            -- Kick any existing live connection for this player
            evictPlayerSession(player.id, peer)

            sessions[ck] = {
                player_id = player.id,
                username  = player.username,
                token     = token
            }
            peerByPlayerId[player.id] = peer

            -- Migrate unlocks for existing players if needed
            local unlocks = player.unlocks
            if not unlocks then
                unlocks = db:migrateUnlocks(player.id)
            end

            peer:send(encode("login_success", {
                player_id         = player.id,
                username          = player.username,
                trophies          = player.trophies,
                coins             = player.coins,
                gold              = player.gold,
                gems              = player.gems,
                xp                = player.xp,
                level             = player.level,
                active_deck_index = player.activeDeckIndex,
                decks             = player.decks,
                token             = token,
                unlocks           = unlocks,
                has_email_backup  = player.hasEmail or false
            }))
            pushLog("Reconnect: " .. player.username)

            -- If they were seated at a live table, put them straight back in.
            TableManager.tryReattach(player.id, peer, ck)
        else
            peer:send(encode("login_failed", {reason = "Invalid or expired token"}))
        end

    elseif eventName == "shop_purchase" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local costs = {gold_1000 = 10, gold_5000 = 50, gold_10000 = 100}
        local gold_amounts = {gold_1000 = 1000, gold_5000 = 5000, gold_10000 = 10000}
        local item = msgData.item
        local gemCost = costs[item]
        local goldGain = gold_amounts[item]

        if not gemCost then
            peer:send(encode("error", {reason = "Unknown item"}))
            return
        end

        local currentGems = db:getGems(session.player_id)
        if currentGems < gemCost then
            peer:send(encode("shop_error", {reason = "Not enough gems"}))
            return
        end

        local newGems = db:addGems(session.player_id, -gemCost)
        local newGold = db:updateGold(session.player_id, goldGain)
        peer:send(encode("currency_update", {gold = newGold, gems = newGems}))
        pushLog("Shop purchase: " .. session.username .. " bought " .. item)

    elseif eventName == "gem_purchase" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local gem_amounts = {gems_10 = 10, gems_50 = 50, gems_100 = 100}
        local package = msgData.package
        local gemGain = gem_amounts[package]

        if not gemGain then
            peer:send(encode("error", {reason = "Unknown package"}))
            return
        end

        local newGems = db:addGems(session.player_id, gemGain)
        local currentGold = db:updateGold(session.player_id, 0)
        pushLog("Gem purchase (mock): " .. session.username .. " +" .. gemGain .. " gems -> newGems=" .. tostring(newGems) .. " gold=" .. tostring(currentGold))
        peer:send(encode("currency_update", {gold = currentGold, gems = newGems}))

    elseif eventName == "claim_reward" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local unlocks = db:claimReward(session.player_id)
        peer:send(encode("reward_claimed", {
            pending_rewards = unlocks and unlocks.pending_rewards or {}
        }))
        pushLog("Reward claimed: " .. session.username)

    elseif eventName == "link_email" then
        local session = sessions[ck]
        if not session then
            peer:send(encode("link_email_failed", {reason = "not_authenticated"}))
            return
        end
        local email = tostring(msgData.email or ""):lower():match("^%s*(.-)%s*$")
        local pw    = tostring(msgData.password or "")
        if not email:match("^[^@]+@[^@]+%.[^@]+$") then
            peer:send(encode("link_email_failed", {reason = "invalid_email"}))
            return
        end
        if #pw < 6 then
            peer:send(encode("link_email_failed", {reason = "password_too_short"}))
            return
        end
        local ok, err = db:linkEmail(session.player_id, email, pw)
        if ok then
            peer:send(encode("link_email_success", {}))
            pushLog("Email linked: " .. session.username .. " -> " .. email)
        else
            peer:send(encode("link_email_failed", {reason = err or "email_taken"}))
            pushLog("Email link failed (" .. tostring(err) .. "): " .. session.username)
        end

    elseif eventName == "login_with_email" then
        local email    = tostring(msgData.email or ""):lower():match("^%s*(.-)%s*$")
        local pw       = tostring(msgData.password or "")
        local deviceId = tostring(msgData.device_id or "")

        local player, err = db:loginWithEmail(email, pw)
        if not player then
            peer:send(encode("login_failed", {reason = "bad_credentials"}))
            pushLog("Email login failed: " .. email)
            return
        end

        db:deletePlayerSessions(player.id)
        evictPlayerSession(player.id, peer)

        -- Bind the recovered account to the new device so future device-login works
        local stmt = db.db:prepare("UPDATE players SET device_id = ?, last_login = strftime('%s','now') WHERE id = ?")
        stmt:bind_values(deviceId, player.id)
        stmt:step()
        stmt:finalize()

        local token = db:createSession(player.id, deviceId)
        sessions[ck] = {
            player_id = player.id,
            username  = player.username,
            token     = token
        }
        peerByPlayerId[player.id] = peer

        local unlocks = player.unlocks
        if not unlocks then
            unlocks = db:migrateUnlocks(player.id)
        end

        peer:send(encode("login_success", {
            player_id         = player.id,
            username          = player.username,
            trophies          = player.trophies,
            coins             = player.coins,
            gold              = player.gold,
            gems              = player.gems,
            xp                = player.xp,
            level             = player.level,
            active_deck_index = player.activeDeckIndex,
            decks             = player.decks,
            token             = token,
            unlocks           = unlocks,
            has_email_backup  = player.hasEmail or false
        }))
        pushLog("Email login: " .. player.username)

    elseif eventName == "mus_action" then
        -- Player intent for the table's engine; validated in TableManager.
        TableManager.handleIntent(ck, msgData)

    elseif eventName == "table_emote" then
        -- Emotes / señas: thin relay to the rest of the table.
        TableManager.handleEmote(ck, msgData)

    elseif eventName == "leave_table" then
        TableManager.leaveTable(ck)
    end
end

local function handleReceive(peer, data)
    if not json then return end

    local ok, decoded = pcall(json.decode, data)
    if ok and type(decoded) == "table" and #decoded == 2 then
        local eventName = decoded[1]
        local msgData = decoded[2] or {}
        handleMessage(peer, eventName, msgData)
    end
    -- Malformed packets are silently dropped (no raw relay — prevents cross-peer data leakage)
end

handleDisconnect = function(peer)
    local raw = tostring(peer)
    local ck  = connKeys[raw]
    if not ck then return end

    -- Remove from queue
    for i = #queue, 1, -1 do
        if connKeys[tostring(queue[i].peer)] == ck then
            pushLog("Queue player disconnected: " .. queue[i].username)
            table.remove(queue, i)
        end
    end

    -- Remove from private queue
    for k, entry in pairs(privateQueue) do
        if connKeys[tostring(entry.peer)] == ck then
            privateQueue[k] = nil
        end
    end

    -- Remove session
    local session = sessions[ck]
    if session then
        peerByPlayerId[session.player_id] = nil
        pushLog("Session closed: " .. session.username)
        sessions[ck] = nil
    end

    -- Detach from any live table (starts the reconnect grace timer)
    TableManager.handleDisconnect(ck)

    connKeys[raw] = nil
end

-- ── Love2D callbacks ────────────────────────────────────────────────────────

function love.load()
    -- Open log file
    logFile = io.open("server/matchmaking.log", "a")
    if logFile then
        logFile:write("\n========== Server Starting ==========\n")
        logFile:flush()
    end

    -- Initialize database
    db = Database.new("server/players.db")
    pushLog("Database initialized")

    -- Table manager owns the per-table engines, bots, and timers
    TableManager.init({ encode = encode, pushLog = pushLog, db = db })

    -- Start ENet host
    host = enet.host_create("*:"..PORT, MAX_CONNECTIONS)
    if not host then
        error("Could not start ENet host on port "..PORT)
    end
    pushLog("Mus Online server started on port "..PORT)
end

function love.update(dt)
    if not host then return end

    -- Process network events
    local event = host:service(0)
    while event do
        if event.type == "connect" then
            handleConnect(event.peer)
        elseif event.type == "receive" then
            handleReceive(event.peer, event.data)
        elseif event.type == "disconnect" then
            handleDisconnect(event.peer)
        end
        event = host:service(0)
    end

    -- Process matchmaking (4-player tables)
    if #queue >= 4 then
        processMatchmaking()
    end

    -- Advance live tables: start delays, turn timeouts, bots, grace timers
    TableManager.update(dt)
end

function love.draw()
    local lg = love.graphics
    lg.setColor(0.1, 0.1, 0.15)
    lg.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

    lg.setColor(1, 1, 1)
    lg.setFont(love.graphics.newFont(14))
    lg.print("Mus Online Server  –  port "..PORT, 10, 10)

    local queueStr = #queue > 0 and (#queue .. " in queue") or "queue empty"
    lg.print("Active Tables: "..TableManager.count().."  |  "..queueStr, 10, 30)

    lg.setColor(0.7, 0.9, 0.7)
    for i, msg in ipairs(log) do
        lg.print(msg, 10, 50 + (i-1)*12)
    end
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end
