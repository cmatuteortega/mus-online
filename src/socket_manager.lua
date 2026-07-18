-- SocketManager: centralized socket health check and reconnection utility.
-- On mobile, backgrounding the app stops love.update() entirely, so ENet
-- connections die after ~30s.  This module provides reconnection on foreground
-- return or after a stale post-game socket is detected.

local sock   = require('lib.sock')
local json   = require('lib.json')
local config = require('src.config')

local SocketManager = {}

--- Check if the current global socket is alive and connected.
function SocketManager.isHealthy()
    return _G.GameSocket ~= nil and _G.GameSocket:isConnected()
end

--- Start an async reconnection using the saved session token.
--- Returns a handle table that the caller must update each frame via
--- SocketManager.updateReconnect(handle, dt).
--- @param onSuccess  function()           called when reconnect succeeds
--- @param onFailure  function(reason:str)  called on failure/timeout
--- @return handle table, or nil if no token available
function SocketManager.reconnect(onSuccess, onFailure)
    local token = _G.PlayerData and _G.PlayerData.token
    if not token then
        if onFailure then onFailure("No session token") end
        return nil
    end

    -- Tear down old socket cleanly
    if _G.GameSocket then
        pcall(function() _G.GameSocket:disconnectNow() end)
        _G.GameSocket = nil
    end

    local client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
    client:setSerialization(json.encode, json.decode)

    local handle = {
        client  = client,
        done    = false,
        elapsed = 0,
        TIMEOUT = 5,
    }

    client:on("connect", function()
        -- Set generous timeout so brief interruptions don't kill the socket
        client:setTimeout(32, 5000, 60000)
        client:send("reconnect_with_token", { token = token, device_id = _G.DeviceId or "" })
    end)

    client:on("login_success", function(data)
        if handle.done then return end
        handle.done = true
        _G.GameSocket = client
        -- Refresh player data with latest from server
        if _G.PlayerData then
            _G.PlayerData.trophies        = data.trophies
            _G.PlayerData.gold            = data.gold or _G.PlayerData.gold
            _G.PlayerData.gems            = data.gems or _G.PlayerData.gems
            _G.PlayerData.xp              = data.xp    or _G.PlayerData.xp or 0
            _G.PlayerData.level           = data.level or _G.PlayerData.level or 1
            _G.PlayerData.activeDeckIndex = data.active_deck_index
            _G.PlayerData.decks           = data.decks
            _G.PlayerData.token           = data.token
            _G.PlayerData.unlocks         = data.unlocks or _G.PlayerData.unlocks
        end
        if onSuccess then onSuccess() end
    end)

    client:on("login_failed", function(data)
        if handle.done then return end
        handle.done = true
        if onFailure then onFailure(data.reason or "Token rejected") end
    end)

    client:on("disconnect", function()
        if handle.done then return end
        handle.done = true
        if onFailure then onFailure("Disconnected during reconnect") end
    end)

    client:connect()
    return handle
end

--- Pump the reconnection handle each frame.
--- @return true when the handle is finished (success or failure), false while in progress
function SocketManager.updateReconnect(handle, dt)
    if not handle or handle.done then return true end
    local ok, err = pcall(function() handle.client:update() end)
    if not ok then
        print("[SocketManager] Reconnect client error: " .. tostring(err))
        handle.done = true
        return true
    end
    handle.elapsed = handle.elapsed + (dt or 0)
    if handle.elapsed >= handle.TIMEOUT then
        handle.done = true
        return true
    end
    return false
end

return SocketManager
