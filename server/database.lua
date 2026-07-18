-- Database wrapper for player persistence
-- Uses lsqlite3 for SQLite operations

-- Set up LuaRocks path (works on both Mac and Linux)
-- On Mac with local install
if love.system.getOS() == "OS X" then
    package.path = package.path .. ';/Users/cmatute1/.luarocks/share/lua/5.1/?.lua;/Users/cmatute1/.luarocks/share/lua/5.1/?/init.lua'
    package.cpath = package.cpath .. ';/Users/cmatute1/.luarocks/lib/lua/5.1/?.so'
end
-- On Linux VPS, system-wide luarocks install will work automatically

local sqlite3 = require("lsqlite3complete")
local bcrypt = require("bcrypt")
local json = require("lib.json")  -- Load json once at module level

local Database = {}
Database.__index = Database

-- Configurable starter pack revealed to new players on first menu visit.
-- Each entry: { unit=string, type="new_unit"|"card" }.
-- "new_unit" shows "NEW!" badge (first copy); "card" shows "+1" badge (extra copy).
-- Edit this table to change what new players receive — no client changes needed.
local STARTER_REWARDS = {
    { unit = "boney",  type = "new_unit" },
    { unit = "boney",  type = "card"     },
    { unit = "marrow", type = "new_unit" },
    { unit = "marrow", type = "card"     },
    { unit = "knight", type = "new_unit" },
    { unit = "knight", type = "card"     },
    { unit = "marc",   type = "new_unit" },
    { unit = "marc",   type = "card"     },
}

-- Forward-declared helpers (defined in the Unlock / Progression section below)
local makeLCG, computeLevelReward, computeRandomCardReward, computeMilestoneReward

-- Initialize database connection
function Database.new(dbPath)
    local self = setmetatable({}, Database)

    -- Open/create database
    self.db = sqlite3.open(dbPath or "server/players.db")

    if not self.db then
        error("Failed to open database")
    end

    -- Create tables if they don't exist
    self:createTables()

    return self
end

-- Create database schema
function Database:createTables()
    local schema = [[
        CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            trophies INTEGER DEFAULT 0,
            coins INTEGER DEFAULT 6,
            active_deck_index INTEGER,
            deck1_json TEXT DEFAULT '{"name":"Deck 1","counts":{}}',
            deck2_json TEXT DEFAULT '{"name":"Deck 2","counts":{}}',
            deck3_json TEXT DEFAULT '{"name":"Deck 3","counts":{}}',
            deck4_json TEXT DEFAULT '{"name":"Deck 4","counts":{}}',
            deck5_json TEXT DEFAULT '{"name":"Deck 5","counts":{}}',
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            last_login INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_username ON players(username);
    ]]

    local result = self.db:exec(schema)
    if result ~= sqlite3.OK then
        error("Failed to create tables: " .. self.db:errmsg())
    end

    -- Migrations: add columns if they don't exist yet
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN gold INTEGER DEFAULT 0") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN gems INTEGER DEFAULT 0") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN xp INTEGER DEFAULT 0") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN level INTEGER DEFAULT 1") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN unlocks_json TEXT") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN device_id TEXT") end)
    pcall(function() self.db:exec("CREATE INDEX IF NOT EXISTS idx_player_device ON players(device_id)") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN email TEXT") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN backup_hash TEXT") end)
    pcall(function()
        self.db:exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_player_email ON players(email) WHERE email IS NOT NULL")
    end)

    -- One-time migration: drop UNIQUE constraint on username (device_id is the real identity)
    local sqlStmt = self.db:prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='players'")
    local needsRebuild = false
    if sqlStmt:step() == sqlite3.ROW then
        local sql = sqlStmt:get_value(0) or ""
        if sql:find("UNIQUE") then
            needsRebuild = true
        end
    end
    sqlStmt:finalize()

    if needsRebuild then
        self.db:exec([[
            BEGIN TRANSACTION;
            CREATE TABLE players_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                trophies INTEGER DEFAULT 0,
                coins INTEGER DEFAULT 6,
                active_deck_index INTEGER,
                deck1_json TEXT,
                deck2_json TEXT,
                deck3_json TEXT,
                deck4_json TEXT,
                deck5_json TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                last_login INTEGER,
                gold INTEGER DEFAULT 0,
                gems INTEGER DEFAULT 0,
                xp INTEGER DEFAULT 0,
                level INTEGER DEFAULT 1,
                unlocks_json TEXT,
                device_id TEXT
            );
            INSERT INTO players_new (id, username, password_hash, trophies, coins, active_deck_index,
                deck1_json, deck2_json, deck3_json, deck4_json, deck5_json, created_at, last_login,
                gold, gems, xp, level, unlocks_json, device_id)
                SELECT id, username, password_hash, trophies, coins, active_deck_index,
                    deck1_json, deck2_json, deck3_json, deck4_json, deck5_json, created_at, last_login,
                    gold, gems, xp, level, unlocks_json, device_id FROM players;
            DROP TABLE players;
            ALTER TABLE players_new RENAME TO players;
            CREATE INDEX idx_username ON players(username);
            CREATE INDEX idx_player_device ON players(device_id);
            COMMIT;
        ]])
        print("[DB] Migrated players table: dropped UNIQUE constraint on username")
    end

    local sessionSchema = [[
        CREATE TABLE IF NOT EXISTS sessions (
            token      TEXT PRIMARY KEY,
            player_id  INTEGER NOT NULL,
            device_id  TEXT NOT NULL DEFAULT '',
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY (player_id) REFERENCES players(id)
        );
        CREATE INDEX IF NOT EXISTS idx_session_player ON sessions(player_id);
    ]]
    self.db:exec(sessionSchema)
end

-- Register a new player
function Database:registerPlayer(username, password)
    -- Check if username already exists
    local stmt = self.db:prepare("SELECT id FROM players WHERE username = ?")
    stmt:bind_values(username)

    if stmt:step() == sqlite3.ROW then
        stmt:finalize()
        return nil, "Username already taken"
    end
    stmt:finalize()

    -- Hash password
    local hash = bcrypt.digest(password, 10) -- 10 rounds

    -- Starter deck: 2 copies of each starter unit
    local starterDeck = '{"name":"Deck 1","counts":{"boney":2,"marrow":2,"knight":2,"marc":2}}'
    local emptyDeck   = '{"name":"Deck %d","counts":{"boney":1}}'

    -- Initial unlock state: starter units with 2 copies each
    local starterUnlocks = json.encode({
        cards = { boney = 2, marrow = 2, knight = 2, marc = 2 },
        pending_rewards = STARTER_REWARDS
    })

    stmt = self.db:prepare([[
        INSERT INTO players (username, password_hash, trophies, coins, active_deck_index,
                           deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
                           unlocks_json)
        VALUES (?, ?, 0, 6, 1, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(username, hash,
        starterDeck,
        string.format(emptyDeck, 2),
        string.format(emptyDeck, 3),
        string.format(emptyDeck, 4),
        string.format(emptyDeck, 5),
        starterUnlocks)

    local result = stmt:step()
    stmt:finalize()

    if result ~= sqlite3.DONE then
        return nil, "Failed to create player"
    end

    -- Get the new player ID
    local playerId = self.db:last_insert_rowid()

    return {
        id = playerId,
        username = username,
        trophies = 0,
        coins = 6,
        gold = 0,
        gems = 0,
        xp = 0,
        level = 1,
        activeDeckIndex = 1,
        decks = {
            json.decode(starterDeck),
            json.decode(string.format(emptyDeck, 2)),
            json.decode(string.format(emptyDeck, 3)),
            json.decode(string.format(emptyDeck, 4)),
            json.decode(string.format(emptyDeck, 5))
        },
        unlocks = json.decode(starterUnlocks)
    }
end

-- Register a player bound to a device (no password, duplicate names allowed)
function Database:registerPlayerByDevice(username, deviceId)
    local starterDeck = '{"name":"Deck 1","counts":{"boney":2,"marrow":2,"knight":2,"marc":2}}'
    local emptyDeck   = '{"name":"Deck %d","counts":{"boney":1}}'

    local starterUnlocks = json.encode({
        cards = { boney = 2, marrow = 2, knight = 2, marc = 2 },
        pending_rewards = STARTER_REWARDS
    })

    local stmt = self.db:prepare([[
        INSERT INTO players (username, password_hash, trophies, coins, active_deck_index,
                           deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
                           unlocks_json, device_id)
        VALUES (?, '', 0, 6, 1, ?, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(username,
        starterDeck,
        string.format(emptyDeck, 2),
        string.format(emptyDeck, 3),
        string.format(emptyDeck, 4),
        string.format(emptyDeck, 5),
        starterUnlocks,
        deviceId or "")

    local result = stmt:step()
    stmt:finalize()

    if result ~= sqlite3.DONE then
        return nil, "Failed to create player"
    end

    local playerId = self.db:last_insert_rowid()

    return {
        id = playerId,
        username = username,
        trophies = 0,
        coins = 6,
        gold = 0,
        gems = 0,
        xp = 0,
        level = 1,
        activeDeckIndex = 1,
        decks = {
            json.decode(starterDeck),
            json.decode(string.format(emptyDeck, 2)),
            json.decode(string.format(emptyDeck, 3)),
            json.decode(string.format(emptyDeck, 4)),
            json.decode(string.format(emptyDeck, 5))
        },
        unlocks = json.decode(starterUnlocks)
    }
end

-- Find the most-recently-active player bound to a device_id, if any
function Database:findPlayerByDevice(deviceId)
    if not deviceId or deviceId == "" then return nil end
    local stmt = self.db:prepare([[
        SELECT id FROM players
        WHERE device_id = ?
        ORDER BY COALESCE(last_login, created_at) DESC
        LIMIT 1
    ]])
    stmt:bind_values(deviceId)
    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil
    end
    local playerId = stmt:get_value(0)
    stmt:finalize()
    return self:getPlayer(playerId)
end

-- Authenticate a player
function Database:loginPlayer(username, password)
    local stmt = self.db:prepare([[
        SELECT id, username, password_hash, trophies, coins, active_deck_index,
               deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
               gold, gems, xp, level, unlocks_json
        FROM players WHERE username = ?
    ]])
    stmt:bind_values(username)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil, "Invalid credentials"
    end

    local playerId = stmt:get_value(0)
    local storedUsername = stmt:get_value(1)
    local passwordHash = stmt:get_value(2)
    local trophies = stmt:get_value(3)
    local coins = stmt:get_value(4)
    local activeDeckIndex = stmt:get_value(5)
    local deck1Json = stmt:get_value(6)
    local deck2Json = stmt:get_value(7)
    local deck3Json = stmt:get_value(8)
    local deck4Json = stmt:get_value(9)
    local deck5Json = stmt:get_value(10)
    local gold = stmt:get_value(11) or 0
    local gems = stmt:get_value(12) or 0
    local xp   = stmt:get_value(13) or 0
    local level = stmt:get_value(14) or 1
    local unlocksJson = stmt:get_value(15)
    stmt:finalize()

    -- Verify password
    if not bcrypt.verify(password, passwordHash) then
        return nil, "Invalid credentials"
    end

    -- Update last login
    stmt = self.db:prepare("UPDATE players SET last_login = strftime('%s', 'now') WHERE id = ?")
    stmt:bind_values(playerId)
    stmt:step()
    stmt:finalize()

    -- Parse deck JSONs
    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    -- Parse unlocks (nil if not yet migrated)
    local unlocks = nil
    if unlocksJson then
        unlocks = json.decode(unlocksJson)
    end

    return {
        id = playerId,
        username = storedUsername,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        xp = xp,
        level = level,
        activeDeckIndex = activeDeckIndex,
        decks = decks,
        unlocks = unlocks
    }
end

-- Create session token (device_id binds token to a specific device)
function Database:createSession(playerId, deviceId)
    -- Purge expired sessions for this player (> 30 days)
    self.db:exec(string.format(
        "DELETE FROM sessions WHERE player_id = %d AND created_at < %d",
        playerId, os.time() - 30 * 24 * 3600
    ))

    -- Generate random token (love.math.random is auto-seeded; plain math.random
    -- is deterministic and would produce repeatable token sequences each restart)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local token = ""
    for _ = 1, 32 do
        local r = love.math.random(1, #chars)
        token = token .. chars:sub(r, r)
    end

    -- Store session with device_id
    local stmt = self.db:prepare("INSERT INTO sessions (token, player_id, device_id) VALUES (?, ?, ?)")
    stmt:bind_values(token, playerId, deviceId or "")
    stmt:step()
    stmt:finalize()

    return token
end

-- Validate session token — also checks device_id match and 30-day expiry
function Database:validateSession(token, deviceId)
    local stmt = self.db:prepare([[
        SELECT s.player_id, s.device_id, s.created_at,
               p.username, p.trophies, p.coins, p.active_deck_index,
               p.deck1_json, p.deck2_json, p.deck3_json, p.deck4_json, p.deck5_json,
               p.gold, p.gems, p.xp, p.level, p.unlocks_json, p.email
        FROM sessions s
        JOIN players p ON s.player_id = p.id
        WHERE s.token = ?
    ]])
    stmt:bind_values(token)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil
    end

    local playerId      = stmt:get_value(0)
    local storedDevice  = stmt:get_value(1)
    local createdAt     = stmt:get_value(2)
    local username      = stmt:get_value(3)
    local trophies      = stmt:get_value(4)
    local coins         = stmt:get_value(5)
    local activeDeckIndex = stmt:get_value(6)
    local deck1Json     = stmt:get_value(7)
    local deck2Json     = stmt:get_value(8)
    local deck3Json     = stmt:get_value(9)
    local deck4Json     = stmt:get_value(10)
    local deck5Json     = stmt:get_value(11)
    local gold          = stmt:get_value(12) or 0
    local gems          = stmt:get_value(13) or 0
    local xp            = stmt:get_value(14) or 0
    local level         = stmt:get_value(15) or 1
    local unlocksJson   = stmt:get_value(16)
    local email         = stmt:get_value(17)
    stmt:finalize()

    -- Reject if device_id doesn't match
    if storedDevice ~= (deviceId or "") then
        return nil
    end

    -- Reject if token is older than 30 days
    if createdAt and (os.time() - createdAt) > 30 * 24 * 3600 then
        return nil
    end

    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    local unlocks = nil
    if unlocksJson then
        unlocks = json.decode(unlocksJson)
    end

    return {
        id = playerId,
        username = username,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        xp = xp,
        level = level,
        activeDeckIndex = activeDeckIndex,
        decks = decks,
        unlocks = unlocks,
        hasEmail = (email ~= nil and email ~= "")
    }
end

-- Delete all sessions for a player (called on credential login to invalidate old tokens)
function Database:deletePlayerSessions(playerId)
    local stmt = self.db:prepare("DELETE FROM sessions WHERE player_id = ?")
    stmt:bind_values(playerId)
    stmt:step()
    stmt:finalize()
end

-- Link an email + password to an existing player for cross-device recovery.
-- Safe to call again with the same email (re-links / updates password).
-- Returns true on success, or false + reason string on failure.
function Database:linkEmail(playerId, email, password)
    local hash = bcrypt.digest(password, 10)
    local stmt = self.db:prepare([[
        UPDATE players SET email = ?, backup_hash = ?
        WHERE id = ? AND (email IS NULL OR email = ?)
    ]])
    stmt:bind_values(email, hash, playerId, email)
    local result = stmt:step()
    stmt:finalize()
    if result ~= sqlite3.DONE then return false, "db_error" end
    if self.db:changes() == 0 then return false, "email_taken" end
    return true
end

-- Authenticate by email + password. Always returns "bad_credentials" on any failure
-- to prevent email enumeration. Returns player table or nil + reason string.
function Database:loginWithEmail(email, password)
    local stmt = self.db:prepare("SELECT id, backup_hash FROM players WHERE email = ?")
    stmt:bind_values(email)
    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil, "bad_credentials"
    end
    local playerId   = stmt:get_value(0)
    local storedHash = stmt:get_value(1)
    stmt:finalize()
    if not storedHash or not bcrypt.verify(password, storedHash) then
        return nil, "bad_credentials"
    end
    return self:getPlayer(playerId)
end

-- Get player by ID
function Database:getPlayer(playerId)
    local stmt = self.db:prepare([[
        SELECT id, username, trophies, coins, active_deck_index,
               deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
               gold, gems, xp, level, unlocks_json, email
        FROM players WHERE id = ?
    ]])
    stmt:bind_values(playerId)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil
    end

    local id = stmt:get_value(0)
    local username = stmt:get_value(1)
    local trophies = stmt:get_value(2)
    local coins = stmt:get_value(3)
    local activeDeckIndex = stmt:get_value(4)
    local deck1Json = stmt:get_value(5)
    local deck2Json = stmt:get_value(6)
    local deck3Json = stmt:get_value(7)
    local deck4Json = stmt:get_value(8)
    local deck5Json = stmt:get_value(9)
    local gold = stmt:get_value(10) or 0
    local gems = stmt:get_value(11) or 0
    local xp   = stmt:get_value(12) or 0
    local level = stmt:get_value(13) or 1
    local unlocksJson = stmt:get_value(14)
    local email       = stmt:get_value(15)
    stmt:finalize()

    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    local unlocks = nil
    if unlocksJson then
        unlocks = json.decode(unlocksJson)
    end

    return {
        id = id,
        username = username,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        xp = xp,
        level = level,
        activeDeckIndex = activeDeckIndex,
        decks = decks,
        unlocks = unlocks,
        hasEmail = (email ~= nil and email ~= "")
    }
end

-- Get top N players by trophy count
function Database:getLeaderboard(limit)
    local stmt = self.db:prepare(
        "SELECT username, trophies FROM players ORDER BY trophies DESC LIMIT ?"
    )
    stmt:bind_values(limit or 5)
    local result = {}
    while stmt:step() == sqlite3.ROW do
        table.insert(result, { username = stmt:get_value(0), trophies = stmt:get_value(1) })
    end
    stmt:finalize()
    return result
end

-- Update player trophies
function Database:updateTrophies(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players
        SET trophies = MAX(0, trophies + ?)
        WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    -- Return new trophy count
    stmt = self.db:prepare("SELECT trophies FROM players WHERE id = ?")
    stmt:bind_values(playerId)

    if stmt:step() == sqlite3.ROW then
        local newTrophies = stmt:get_value(0)
        stmt:finalize()
        return newTrophies
    end

    stmt:finalize()
    return 0
end

-- Add XP to a player, handling level-ups and unlock rewards.
-- Returns {xp, level, unlocks} where unlocks is the full unlock state (or nil if unchanged).
function Database:updateXP(playerId, amount)
    local stmt = self.db:prepare("SELECT xp, level FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local xp, level = 0, 1
    if stmt:step() == sqlite3.ROW then
        xp    = stmt:get_value(0) or 0
        level = stmt:get_value(1) or 1
    end
    stmt:finalize()

    local oldLevel = level
    xp = xp + amount

    -- Level-up loop: xpNeeded = 30 + floor((level-1)/10) * 5
    local function xpForLevel(lvl)
        return 30 + math.floor((lvl - 1) / 10) * 5
    end
    while xp >= xpForLevel(level) do
        xp = xp - xpForLevel(level)
        level = level + 1
    end

    stmt = self.db:prepare("UPDATE players SET xp = ?, level = ? WHERE id = ?")
    stmt:bind_values(xp, level, playerId)
    stmt:step()
    stmt:finalize()

    -- Compute unlock rewards for each new level reached
    local unlocks = nil
    if level > oldLevel then
        unlocks = self:getUnlocks(playerId)
        if not unlocks then
            unlocks = self:migrateUnlocks(playerId)
        end
        -- Ensure pending_rewards exists
        if not unlocks.pending_rewards then unlocks.pending_rewards = {} end

        for lvl = oldLevel + 1, level do
            local rng = function(n) return math.random(n) end
            local reward = computeLevelReward(lvl, unlocks, rng)
            if reward then
                -- Apply card grant immediately
                if reward.type == "new_unit" then
                    unlocks.cards[reward.unit] = 1
                elseif reward.type == "card" then
                    unlocks.cards[reward.unit] = (unlocks.cards[reward.unit] or 0) + 1
                end
                -- Add to pending for client reveal animation
                reward.level = lvl
                table.insert(unlocks.pending_rewards, reward)
            end
        end

        self:setUnlocks(playerId, unlocks)
    end

    return { xp = xp, level = level, unlocks = unlocks }
end

-- Add gold to a player (delta can be negative)
function Database:updateGold(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players SET gold = MAX(0, gold + ?) WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    stmt = self.db:prepare("SELECT gold FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local newGold = 0
    if stmt:step() == sqlite3.ROW then newGold = stmt:get_value(0) end
    stmt:finalize()
    return newGold
end

-- Add gems to a player (delta can be negative)
function Database:addGems(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players SET gems = MAX(0, gems + ?) WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    stmt = self.db:prepare("SELECT gems FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local newGems = 0
    if stmt:step() == sqlite3.ROW then newGems = stmt:get_value(0) end
    stmt:finalize()
    return newGems
end

-- Get a player's current gems
function Database:getGems(playerId)
    local stmt = self.db:prepare("SELECT gems FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local gems = 0
    if stmt:step() == sqlite3.ROW then gems = stmt:get_value(0) end
    stmt:finalize()
    return gems
end

-- Update a specific deck slot (1-5)
function Database:updateDeckSlot(playerId, deckIndex, deckData)
    if deckIndex < 1 or deckIndex > 5 then
        return false, "Invalid deck index"
    end

    local deckJson = json.encode(deckData)
    local columnName = "deck" .. deckIndex .. "_json"

    local stmt = self.db:prepare("UPDATE players SET " .. columnName .. " = ? WHERE id = ?")
    stmt:bind_values(deckJson, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- Update active deck index
function Database:updateActiveDeck(playerId, deckIndex)
    local stmt = self.db:prepare("UPDATE players SET active_deck_index = ? WHERE id = ?")
    stmt:bind_values(deckIndex, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- Update all deck data at once (for bulk sync)
function Database:updateAllDecks(playerId, activeDeckIndex, decks)
    if #decks ~= 5 then
        return false, "Must provide exactly 5 decks"
    end

    local stmt = self.db:prepare([[
        UPDATE players
        SET active_deck_index = ?,
            deck1_json = ?, deck2_json = ?, deck3_json = ?, deck4_json = ?, deck5_json = ?
        WHERE id = ?
    ]])

    stmt:bind_values(
        activeDeckIndex,
        json.encode(decks[1]),
        json.encode(decks[2]),
        json.encode(decks[3]),
        json.encode(decks[4]),
        json.encode(decks[5]),
        playerId
    )

    stmt:step()
    stmt:finalize()

    return true
end

-- Update player coins
function Database:updateCoins(playerId, coins)
    local stmt = self.db:prepare("UPDATE players SET coins = ? WHERE id = ?")
    stmt:bind_values(coins, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- ── Unlock / Progression System ─────────────────────────────────────────

-- Starter units and rarity tiers (mirrors unit_registry.lua constants)
local STARTER_UNITS  = { "boney", "marrow", "knight", "marc" }
local STARTER_COPIES = 2
local MAX_COPIES     = 4

-- Rarity tiers: commons exhausted first, then rares, then epics.
-- Within a tier, milestone rewards pick randomly.
local RARITY_TIERS = {
    { tier = "common", units = { "burrow", "amalgam", "mage", "bull", "arrows", "fireball" } },
    { tier = "rare",   units = { "samurai", "bonk", "clavicula", "humerus" } },
    { tier = "epic",   units = { "migraine", "tomb", "sinner", "catapult" } },
}

local function isMilestone(level)
    return level >= 5 and level % 5 == 0
end

-- Simple deterministic LCG RNG (no dependency on math.random state)
makeLCG = function(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        if n then return (s % n) + 1 end
        return s
    end
end

-- Pick a random card from already-unlocked units that have < MAX_COPIES.
-- Returns { type="card", unit=name } or nil.
computeRandomCardReward = function(unlocks, rngFunc)
    local pool = {}
    for unit, count in pairs(unlocks.cards) do
        if count > 0 and count < MAX_COPIES then
            table.insert(pool, unit)
        end
    end
    if #pool == 0 then return nil end
    table.sort(pool) -- deterministic iteration
    local idx = rngFunc(#pool)
    return { type = "card", unit = pool[idx] }
end

-- Pick a random not-yet-unlocked unit from the lowest available rarity tier.
-- Returns { type="new_unit", unit=name } or nil.
computeMilestoneReward = function(unlocks, rngFunc)
    for _, tierInfo in ipairs(RARITY_TIERS) do
        local available = {}
        for _, unit in ipairs(tierInfo.units) do
            if not unlocks.cards[unit] or unlocks.cards[unit] == 0 then
                table.insert(available, unit)
            end
        end
        if #available > 0 then
            local idx = rngFunc(#available)
            return { type = "new_unit", unit = available[idx] }
        end
    end
    -- All units unlocked; fall back to random card reward
    return computeRandomCardReward(unlocks, rngFunc)
end

-- Compute the reward for reaching a given level.
computeLevelReward = function(level, unlocks, rngFunc)
    if level < 2 then return nil end
    if isMilestone(level) then
        return computeMilestoneReward(unlocks, rngFunc)
    else
        return computeRandomCardReward(unlocks, rngFunc)
    end
end

-- Read unlock state for a player. Returns table or nil.
function Database:getUnlocks(playerId)
    local stmt = self.db:prepare("SELECT unlocks_json FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local result = nil
    if stmt:step() == sqlite3.ROW then
        local raw = stmt:get_value(0)
        if raw then result = json.decode(raw) end
    end
    stmt:finalize()
    return result
end

-- Write unlock state for a player.
function Database:setUnlocks(playerId, unlocks)
    local encoded = json.encode(unlocks)
    local stmt = self.db:prepare("UPDATE players SET unlocks_json = ? WHERE id = ?")
    stmt:bind_values(encoded, playerId)
    stmt:step()
    stmt:finalize()
end

-- Migrate unlocks for existing players who have no unlocks_json yet.
-- Simulates all rewards from level 2 to the player's current level using
-- a deterministic RNG seeded per player+level, so the result is reproducible.
function Database:migrateUnlocks(playerId)
    local stmt = self.db:prepare("SELECT level FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local level = 1
    if stmt:step() == sqlite3.ROW then
        level = stmt:get_value(0) or 1
    end
    stmt:finalize()

    -- Start with starter cards
    local unlocks = { cards = {}, pending_rewards = {} }
    for _, unit in ipairs(STARTER_UNITS) do
        unlocks.cards[unit] = STARTER_COPIES
    end

    -- Simulate each level-up reward
    for lvl = 2, level do
        local rng = makeLCG(playerId * 1000 + lvl)
        local reward = computeLevelReward(lvl, unlocks, rng)
        if reward then
            if reward.type == "new_unit" then
                unlocks.cards[reward.unit] = 1
            elseif reward.type == "card" then
                unlocks.cards[reward.unit] = (unlocks.cards[reward.unit] or 0) + 1
            end
            -- No pending rewards for migration (retroactive)
        end
    end

    self:setUnlocks(playerId, unlocks)
    return unlocks
end

-- Award a card of the given unit type and queue it in pending_rewards.
-- Updates unlocks_json in the database. Returns updated unlocks.
function Database:awardCard(playerId, unitType)
    local unlocks = self:getUnlocks(playerId)
    if not unlocks then return nil end
    unlocks.cards = unlocks.cards or {}
    unlocks.cards[unitType] = (unlocks.cards[unitType] or 0) + 1
    unlocks.pending_rewards = unlocks.pending_rewards or {}
    table.insert(unlocks.pending_rewards, { unit = unitType, type = "card" })
    self:setUnlocks(playerId, unlocks)
    return unlocks
end

-- Claim (remove) the first pending reward. Returns updated unlocks.
function Database:claimReward(playerId)
    local unlocks = self:getUnlocks(playerId)
    if not unlocks or not unlocks.pending_rewards or #unlocks.pending_rewards == 0 then
        return unlocks
    end
    table.remove(unlocks.pending_rewards, 1)
    self:setUnlocks(playerId, unlocks)
    return unlocks
end

-- Close database connection
function Database:close()
    if self.db then
        self.db:close()
    end
end

return Database
