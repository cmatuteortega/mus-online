-- Mus Online – Preload Splash
-- Loads sprites incrementally (one step per frame) while a progress bar draws,
-- authenticating in parallel; on success goes to menu. Auth failures retry up
-- to MAX_RETRIES then show "Sin conexión" with tap-to-retry plus an offline
-- sandbox option (play vs bots, no server).
-- Only "no_device_profile" goes to name_entry (legitimate new-user signup path).

local Screen       = require('lib.screen')
local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')
local sock         = require('lib.sock')
local json         = require('lib.json')
local config       = require('src.config')

local PreloadScreen = {}

function PreloadScreen.new()
    local self = Screen.new()

    function self:init()
        self.steps        = UnitRegistry.getLoadSteps()
        self.total        = #self.steps
        self.index        = 1
        self.spritesDone  = false
        self.warmup       = true

        -- Title artwork: shadow drawn fixed, title floats with a sine wave above it.
        self.titleImg    = love.graphics.newImage("title.png")
        self.titleShadow = love.graphics.newImage("title_shadow.png")
        self.titleImg:setFilter('nearest', 'nearest')
        self.titleShadow:setFilter('nearest', 'nearest')

        self.authStatus     = "connecting"  -- connecting | authing | success | retrying | no_network | name_entry
        self.client         = nil
        self.elapsed        = 0
        self.TIMEOUT        = 5
        self.RETRY_DELAY    = 1.5
        self.MAX_RETRIES    = 2
        self.retryTimer     = 0
        self.retryCount     = 0
        self.token          = nil
        self.storedUsername = nil
        self.authMode       = "device"
        self.advanced       = false

        -- The AutoChest tutorial is gone in the mus migration: every boot goes
        -- through auth. Offline play is reachable from the "Sin conexión"
        -- screen (sandbox vs bots) instead.
        self.tutorialPending = false

        if not self.tutorialPending then
            local raw = love.filesystem.read("session.dat") or ""
            local ok, parsed = pcall(json.decode, raw)
            if ok and parsed and parsed.token then
                self.token          = parsed.token
                self.storedUsername = parsed.username
                self.authMode       = "token"
            else
                love.filesystem.remove("session.dat")
                self.authMode = "device"
            end

            self:connectToServer()
        end
    end

    function self:close()
        if self.client and self.authStatus ~= "success" then
            pcall(function() self.client:disconnect() end)
        end
    end

    function self:dropClient()
        if self.client then
            pcall(function() self.client:disconnect() end)
            self.client = nil
        end
    end

    function self:scheduleRetry()
        if self.advanced then return end
        self:dropClient()
        self.retryCount = self.retryCount + 1
        if self.retryCount > self.MAX_RETRIES then
            self.authStatus = "no_network"
            return
        end
        self.authStatus = "retrying"
        self.retryTimer = self.RETRY_DELAY
        self.elapsed    = 0
    end

    function self:manualRetry()
        if self.advanced then return end
        if self.authStatus ~= "no_network" then return end
        self.retryCount = 0
        self.retryTimer = 0
        self.elapsed    = 0
        self.authStatus = "retrying"
    end

    function self:connectToServer()
        self.authStatus = "connecting"
        self.elapsed    = 0

        local ok, err = pcall(function()
            self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
            self.client:setSerialization(json.encode, json.decode)

            self.client:on("connect", function()
                self.authStatus = "authing"
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
                if self.authStatus ~= "success" then
                    self:scheduleRetry()
                end
            end)

            self.client:on("login_success", function(data)
                self.authStatus = "success"

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
                    hasEmailBackup  = data.has_email_backup or false
                }
                _G.GameSocket = self.client

                if data.token and data.token ~= "" then
                    love.filesystem.write("session.dat", json.encode({
                        token          = data.token,
                        username       = data.username,
                        hasEmailBackup = data.has_email_backup or false,
                    }))
                end

                self:tryAdvance()
            end)

            self.client:on("login_failed", function(data)
                local reason = (data and data.reason) or "Login failed"

                if reason == "no_device_profile" then
                    love.filesystem.remove("session.dat")
                    self:gotoNameEntry()
                elseif self.authMode == "token" then
                    love.filesystem.remove("session.dat")
                    self.token      = nil
                    self.authMode   = "device"
                    self.authStatus = "authing"
                    self.elapsed    = 0
                    self.client:send("login_with_device", {
                        device_id = _G.DeviceId or ""
                    })
                else
                    self:scheduleRetry()
                end
            end)

            self.client:connect()
            self.client:setTimeout(32, 5000, 60000)
        end)

        if not ok then
            print("[PRELOAD] connect error: " .. tostring(err))
            self:scheduleRetry()
        end
    end

    function self:gotoNameEntry()
        if self.advanced then return end
        self.advanced = true
        if self.client then
            pcall(function() self.client:disconnect() end)
        end
        if not self.spritesDone then
            for i = self.index, self.total do
                local step = self.steps[i]
                if step then step() end
            end
            UnitRegistry.finalizeSprites()
            self.spritesDone = true
        end
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('name_entry')
    end

    function self:tryAdvance()
        if self.advanced then return end
        if not self.spritesDone then return end
        local ScreenManager = require('lib.screen_manager')

        if self.authStatus == "success" then
            self.advanced = true
            TransitionManager.cloudCurtain(function()
                ScreenManager.switch('menu')
            end)
        end
    end

    function self:update(dt)
        if self.advanced then return end

        if not self.tutorialPending then
            if self.client then
                local ok, err = pcall(function() self.client:update() end)
                if not ok then
                    print("[PRELOAD] socket error: " .. tostring(err))
                    self:scheduleRetry()
                end
            end

            if self.authStatus == "retrying" then
                self.retryTimer = self.retryTimer - dt
                if self.retryTimer <= 0 then
                    self:connectToServer()
                end
            elseif self.authStatus == "connecting" or self.authStatus == "authing" then
                self.elapsed = self.elapsed + dt
                if self.elapsed >= self.TIMEOUT then
                    self:scheduleRetry()
                end
            end
        end

        if not self.spritesDone then
            if self.warmup then
                self.warmup = false
            else
                local step = self.steps[self.index]
                if step then
                    step()
                    self.index = self.index + 1
                end
                if self.index > self.total then
                    UnitRegistry.finalizeSprites()
                    self.spritesDone = true
                    self:tryAdvance()
                end
            end
        end
    end

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Title with a static drop shadow (shadow drawn below the title)
        local titleScale = 12
        local tw = self.titleImg:getWidth()  * titleScale
        local th = self.titleImg:getHeight() * titleScale
        local titleX  = math.floor((W - tw) / 2)
        local titleY  = math.floor(H / 3 - th / 2)
        local shadowDrop = math.floor(8 * sc)
        lg.setColor(1, 1, 1, 1)
        lg.draw(self.titleShadow, titleX, titleY + shadowDrop, 0, titleScale, titleScale)
        lg.draw(self.titleImg,    titleX, titleY, 0, titleScale, titleScale)

        local barW  = W * 0.6
        local barH  = 16 * sc
        local barX  = (W - barW) / 2
        local barY  = H * 0.8
        local ratio = (self.index - 1) / math.max(1, self.total)
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end

        lg.setColor(0.2, 0.25, 0.35, 1)
        lg.rectangle('fill', barX, barY, barW, barH)

        lg.setColor(0.5, 0.7, 1, 1)
        lg.rectangle('fill', barX, barY, barW * ratio, barH)

        lg.setColor(1, 1, 1, 1)
        lg.setLineWidth(2 * sc)
        lg.rectangle('line', barX, barY, barW, barH)

        if self.authStatus == "no_network" then
            lg.setFont(Fonts.medium)
            lg.setColor(1, 0.5, 0.5, 1)
            lg.printf("Sin conexión a internet",
                      0, barY + barH + 14 * sc, W, 'center')

            -- Two options: retry the connection, or play offline vs bots.
            local optY = barY + barH + 14 * sc + Fonts.medium:getHeight() + 10 * sc
            lg.setFont(Fonts.small)
            lg.setColor(0.85, 0.85, 0.9, 1)
            lg.printf("Toca para reintentar", 0, optY, W, 'center')
            local offY = optY + Fonts.small:getHeight() + 12 * sc
            lg.setColor(0.6, 0.9, 0.7, 1)
            lg.printf("Jugar OFFLINE contra bots", 0, offY, W, 'center')
            self._offlineRect = { x = 0, y = offY - 8 * sc, w = W,
                                  h = Fonts.small:getHeight() + 16 * sc }
        else
            self._offlineRect = nil
            lg.setFont(Fonts.small)
            lg.setColor(0.8, 0.8, 0.85, 1)
            lg.printf(string.format("%d%%", math.floor(ratio * 100 + 0.5)),
                      0, barY + barH + 10 * sc, W, 'center')
        end
    end

    function self:launchOfflineSandbox()
        if self.advanced then return end
        self.advanced = true
        self:dropClient()
        local ScreenManager = require('lib.screen_manager')
        -- (isOnline=false, seat=1, socket=false, sandbox=true) — same call the
        -- menu's SANDBOX button makes.
        ScreenManager.switch('game', false, 1, false, true)
    end

    function self:handleTap(x, y)
        if self.authStatus ~= "no_network" then return end
        local r = self._offlineRect
        if r and x and y and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            self:launchOfflineSandbox()
        else
            self:manualRetry()
        end
    end

    function self:mousereleased(x, y, button)
        if button == 1 then self:handleTap(x, y) end
    end

    function self:touchreleased(_, x, y)
        self:handleTap(x, y)
    end

    function self:keypressed(key)
        if key == "return" or key == "space" then
            self:manualRetry()
        end
    end

    return self
end

return PreloadScreen
