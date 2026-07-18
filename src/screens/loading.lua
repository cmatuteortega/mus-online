-- Mus Online – Loading / Auto-Auth Screen
-- Always auto-authenticates. Two paths:
--   1. session.dat has a token → send `reconnect_with_token`
--   2. No token → send `login_with_device` (server looks up player by device_id)
-- If the device has no profile yet → switch to name_entry.
-- On any other failure/timeout → also switch to name_entry as a last resort.

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local config    = require('src.config')
local sock      = require('lib.sock')
local json      = require('lib.json')

local LoadingScreen = {}

function LoadingScreen.new()
    local self = Screen.new()

    function self:init()
        self.status    = "connecting"
        self.statusMsg = "Connecting..."
        self.client    = nil
        self.elapsed   = 0
        self.TIMEOUT   = 5
        self.dotTimer  = 0
        self.dotCount  = 0
        self.token                = nil
        self.storedUsername       = nil
        self.storedHasEmailBackup = false
        self.authMode             = "device"  -- "token" or "device"

        -- Parse session.dat as JSON {token, username}; fall through to device login if missing/invalid
        local raw = love.filesystem.read("session.dat") or ""
        local ok, parsed = pcall(json.decode, raw)
        if ok and parsed and parsed.token then
            self.token                = parsed.token
            self.storedUsername       = parsed.username
            self.storedHasEmailBackup = parsed.hasEmailBackup or false
            self.authMode             = "token"
        else
            love.filesystem.remove("session.dat")
            self.authMode = "device"
        end

        self:connectToServer()
    end

    function self:close()
        if self.client and self.status ~= "success" then
            self.client:disconnect()
        end
    end

    function self:connectToServer()
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status    = "authing"
            self.statusMsg = "Authenticating..."
            if self.authMode == "token" then
                self.client:send("reconnect_with_token", {
                    token     = self.token,
                    device_id = _G.DeviceId or ""
                })
            else
                self.client:send("login_with_device", {
                    device_id = _G.DeviceId or ""
                })
            end
        end)

        self.client:on("disconnect", function()
            if self.status ~= "success" then
                self:fallbackToNameEntry("Disconnected from server")
            end
        end)

        self.client:on("login_success", function(data)
            self.status = "success"
            print("[DEBUG] login_success has_email_backup=" .. tostring(data.has_email_backup)
                  .. " storedHasEmailBackup=" .. tostring(self.storedHasEmailBackup))

            _G.PlayerData = {
                id              = data.player_id,
                username        = data.username,
                trophies        = data.trophies,
                coins           = data.coins,
                gold            = data.gold or 0,
                gems            = data.gems or 0,
                xp              = data.xp or 0,
                level           = data.level or 1,
                activeDeckIndex = data.active_deck_index,
                decks           = data.decks,
                token           = data.token,
                unlocks         = data.unlocks,
                hasEmailBackup  = data.has_email_backup or self.storedHasEmailBackup or false
            }
            _G.GameSocket = self.client

            -- Refresh session.dat with the fresh token (device-login issues a new one too)
            if data.token and data.token ~= "" then
                love.filesystem.write("session.dat", json.encode({
                    token          = data.token,
                    username       = data.username,
                    hasEmailBackup = data.has_email_backup or false,
                }))
            end

            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end)

        self.client:on("login_failed", function(data)
            local reason = (data and data.reason) or "Login failed"
            love.filesystem.remove("session.dat")

            if reason == "no_device_profile" then
                -- First-time device: go collect a name
                self:gotoNameEntry()
            elseif self.authMode == "token" then
                -- Token was bad; retry with device login before giving up
                self.authMode = "device"
                self.status   = "authing"
                self.statusMsg = "Authenticating..."
                self.elapsed  = 0
                self.client:send("login_with_device", {
                    device_id = _G.DeviceId or ""
                })
            else
                self:fallbackToNameEntry(reason)
            end
        end)

        self.client:connect()
        self.client:setTimeout(32, 5000, 60000)
    end

    function self:gotoNameEntry()
        self.status = "name_entry"
        if self.client then
            pcall(function() self.client:disconnect() end)
        end
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('name_entry')
    end

    function self:fallbackToNameEntry(reason)
        self.status    = "failed"
        self.statusMsg = reason
        love.timer.sleep(1.0)
        self:gotoNameEntry()
    end

    function self:enterNoNetwork()
        self.status    = "failed"
        self.statusMsg = "Sin conexión a internet"
        if self.client then
            pcall(function() self.client:disconnect() end)
            self.client = nil
        end
    end

    function self:manualRetry()
        if self.status ~= "failed" then return end
        self.status    = "connecting"
        self.statusMsg = "Connecting..."
        self.elapsed   = 0
        self:connectToServer()
    end

    function self:update(dt)
        if self.client then
            local ok, err = pcall(function() self.client:update() end)
            if not ok then
                print("[LOADING] socket error: " .. tostring(err))
                self:enterNoNetwork()
            end
        end

        if self.status == "connecting" or self.status == "authing" then
            self.elapsed = self.elapsed + dt
            if self.elapsed >= self.TIMEOUT then
                self:enterNoNetwork()
                return
            end
        end

        self.dotTimer = self.dotTimer + dt
        if self.dotTimer >= 0.4 then
            self.dotTimer = 0
            self.dotCount = (self.dotCount + 1) % 4
        end
    end

    function self:mousereleased(_, _, button)
        if button == 1 then self:manualRetry() end
    end

    function self:touchreleased()
        self:manualRetry()
    end

    function self:keypressed(key)
        if key == "return" or key == "space" then
            self:manualRetry()
        end
    end

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE

        lg.clear(Constants.COLORS.BACKGROUND)

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("MUS", 0, H * 0.10, W, 'center')

        if self.status == "connecting" or self.status == "authing" then
            local angle    = love.timer.getTime() * math.pi
            local spinnerR = 40 * sc
            local cx, cy   = W / 2, H * 0.45

            lg.push()
            lg.translate(cx, cy)
            lg.rotate(angle)
            lg.setColor(0.5, 0.7, 1, 1)
            lg.setLineWidth(4 * sc)
            lg.arc('line', 'open', 0, 0, spinnerR, 0, math.pi * 1.5)
            lg.pop()
        end

        if self.storedUsername and self.authMode == "token"
           and (self.status == "connecting" or self.status == "authing") then
            lg.setFont(Fonts.small)
            lg.setColor(0.7, 0.7, 0.75, 1)
            lg.printf("Continuing as " .. self.storedUsername, 0, H * 0.34, W, 'center')
        end

        local dots = string.rep(".", self.dotCount)
        lg.setFont(Fonts.medium)
        if self.status == "failed" then
            lg.setColor(1, 0.4, 0.4, 1)
            lg.printf(self.statusMsg, 0, H * 0.56, W, 'center')
            lg.setFont(Fonts.small)
            lg.setColor(0.85, 0.85, 0.9, 1)
            lg.printf("Toca para reintentar",
                      0, H * 0.56 + Fonts.medium:getHeight() + 6 * sc, W, 'center')
        else
            lg.setColor(0.8, 0.8, 0.85, 1)
            lg.printf(self.statusMsg .. dots, 0, H * 0.56, W, 'center')
        end
    end

    return self
end

return LoadingScreen
