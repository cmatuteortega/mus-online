-- Mus Online – Name Entry Screen
-- First-time onboarding: collect the player's display name and auto-register
-- the device. Runs once per device (re-entry is handled idempotently by the
-- server — submitting a name for a device that already has a profile reuses it).
-- Also hosts the "Restore Account" flow for recovering an account by email.

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local config    = require('src.config')
local sock      = require('lib.sock')
local json      = require('lib.json')

local MAX_NAME_LEN = 16

local NameEntryScreen = {}

function NameEntryScreen.new()
    local self = Screen.new()

    function self:init()
        -- register mode state
        self.nameText    = ""
        self.activeField = "name"

        -- restore mode state
        self.mode         = "register"   -- "register" | "restore"
        self.emailText    = ""
        self.passwordText = ""
        self._restoreStatus   = nil
        self._restoreBtnRect  = nil
        self._emailRect       = nil
        self._passwordRect    = nil
        self._submitBtnRect   = nil
        self._backBtnRect     = nil

        self.status = "connecting"
        self.statusMessage = "Connecting to server..."

        self.client = nil

        self.cursorTimer = 0
        self.cursorVisible = true

        self._nameRect = nil
        self._playBtnRect = nil

        self:connectToServer()

        love.keyboard.setKeyRepeat(true)
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        love.keyboard.setTextInput(false)
        if self.client and self.status ~= "logged_in" then
            self.client:disconnect()
        end
    end

    function self:connectToServer()
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status = "ready"
            self.statusMessage = "What's your name?"
        end)

        self.client:on("disconnect", function()
            if self.status ~= "logged_in" then
                self.status = "error"
                self.statusMessage = "Disconnected from server"
            end
        end)

        self.client:on("login_success", function(data)
            self.status = "logged_in"
            self.statusMessage = "Welcome, " .. tostring(data.username) .. "!"

            if data.token and data.token ~= "" then
                love.filesystem.write("session.dat", json.encode({
                    token          = data.token,
                    username       = data.username,
                    hasEmailBackup = data.has_email_backup or false,
                }))
            end

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

            love.timer.sleep(0.4)
            TransitionManager.cloudCurtain(function()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('menu')
            end)
        end)

        self.client:on("register_failed", function(data)
            self.status = "error"
            self.statusMessage = (data and data.reason) or "Registration failed"
        end)

        self.client:on("login_failed", function(data)
            if self.mode == "restore" then
                self._restoreStatus = "Invalid email or password"
                self.status = "ready"
                self.statusMessage = "What's your name?"
            else
                self.status = "error"
                self.statusMessage = (data and data.reason) or "Login failed"
            end
        end)

        self.client:connect()
        self.client:setTimeout(32, 5000, 60000)
    end

    function self:update(dt)
        if self.client then
            self.client:update()
        end

        self.cursorTimer = self.cursorTimer + dt
        if self.cursorTimer >= 0.5 then
            self.cursorTimer = 0
            self.cursorVisible = not self.cursorVisible
        end
    end

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    local function textCY(font, boxY, boxH)
        return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
    end

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE
        local cx = W / 2

        lg.clear(Constants.COLORS.BACKGROUND)

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("MUS", 0, H * 0.10, W, 'center')

        lg.setFont(Fonts.small)
        if self.status == "error" then
            lg.setColor(1, 0.4, 0.4, 1)
        elseif self.status == "connecting" then
            lg.setColor(0.7, 0.7, 0.7, 1)
        else
            lg.setColor(0.6, 1, 0.6, 1)
        end
        lg.printf(self.statusMessage, 0, H * 0.10 + Fonts.large:getHeight() + 20 * sc, W, 'center')

        if self.status ~= "connecting" and self.status ~= "logged_in" then
            if self.mode == "register" then
                self:drawRegisterMode(lg, W, H, sc, cx, textCY, roundedRect, roundedRectLine)
            elseif self.mode == "restore" then
                self:drawRestoreMode(lg, W, H, sc, cx, textCY, roundedRect, roundedRectLine)
            end
        end
    end

    function self:drawRegisterMode(lg, W, H, sc, cx, textCY, roundedRect, roundedRectLine)
        local fieldW   = 300 * sc
        local fieldH   = 50 * sc
        local fieldX   = cx - fieldW / 2
        local labelGap = 8 * sc
        local textPad  = 12 * sc

        local nameY = H * 0.38
        lg.setFont(Fonts.small)
        lg.setColor(0.65, 0.65, 0.7, 1)
        lg.print("Name", fieldX, nameY - Fonts.small:getHeight() - labelGap)

        local active = (self.activeField == "name")
        lg.setColor(active and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
        roundedRect(fieldX, nameY, fieldW, fieldH, 5, sc)
        lg.setColor(active and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
        roundedRectLine(fieldX, nameY, fieldW, fieldH, 5, sc, 2 * sc)

        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        local textY = textCY(Fonts.small, nameY, fieldH)
        lg.print(self.nameText, fieldX + textPad, textY)

        if active and self.cursorVisible then
            local tw = Fonts.small:getWidth(self.nameText)
            lg.setColor(1, 1, 1, 0.85)
            lg.rectangle('fill', fieldX + textPad + tw + 1, textY + 2 * sc,
                         2 * sc, Fonts.small:getHeight() - 4 * sc)
        end

        self._nameRect = {x = fieldX, y = nameY, w = fieldW, h = fieldH}

        local btnW = 180 * sc
        local btnH = 54 * sc
        local btnX = cx - btnW / 2
        local btnY = nameY + fieldH + 44 * sc

        local canSubmit = #self.nameText > 0

        if canSubmit then
            lg.setColor(0.15, 0.45, 0.25, 1)
            roundedRect(btnX, btnY, btnW, btnH, 8, sc)
            lg.setColor(0.25, 0.65, 0.40, 1)
            roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
        else
            lg.setColor(0.12, 0.12, 0.18, 1)
            roundedRect(btnX, btnY, btnW, btnH, 8, sc)
            lg.setColor(0.22, 0.22, 0.30, 1)
            roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
        end
        lg.setFont(Fonts.medium)
        lg.setColor(canSubmit and {1, 1, 1, 1} or {0.4, 0.4, 0.45, 1})
        lg.printf("Play!", btnX, textCY(Fonts.medium, btnY, btnH), btnW, 'center')
        self._playBtnRect = canSubmit and {x = btnX, y = btnY, w = btnW, h = btnH} or nil

        -- Restore Account secondary button
        local restW = 230 * sc
        local restH = 36 * sc
        local restX = cx - restW / 2
        local restY = btnY + btnH + 18 * sc
        lg.setColor(0.10, 0.10, 0.16, 1)
        roundedRect(restX, restY, restW, restH, 6, sc)
        lg.setColor(0.22, 0.22, 0.32, 1)
        roundedRectLine(restX, restY, restW, restH, 6, sc, math.max(1, math.floor(sc)))
        lg.setFont(Fonts.small)
        lg.setColor(0.5, 0.5, 0.7, 1)
        lg.printf("Restore Account", restX, textCY(Fonts.small, restY, restH), restW, 'center')
        self._restoreBtnRect = {x = restX, y = restY, w = restW, h = restH}
    end

    function self:drawRestoreMode(lg, W, H, sc, cx, textCY, roundedRect, roundedRectLine)
        -- Error / status message
        if self._restoreStatus then
            lg.setFont(Fonts.small)
            lg.setColor(1, 0.4, 0.4, 1)
            lg.printf(self._restoreStatus, 0, H * 0.26, W, 'center')
        end

        local fieldW = 300 * sc
        local fieldH = 50 * sc
        local fieldX = cx - fieldW / 2
        local labelGap = 8 * sc
        local textPad  = 12 * sc

        -- Email field
        local emailY = H * 0.35
        lg.setFont(Fonts.small)
        lg.setColor(0.65, 0.65, 0.7, 1)
        lg.print("Email", fieldX, emailY - Fonts.small:getHeight() - labelGap)

        local emailActive = (self.activeField == "email")
        lg.setColor(emailActive and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
        roundedRect(fieldX, emailY, fieldW, fieldH, 5, sc)
        lg.setColor(emailActive and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
        roundedRectLine(fieldX, emailY, fieldW, fieldH, 5, sc, 2 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(#self.emailText == 0 and {0.4, 0.4, 0.45, 1} or {1, 1, 1, 1})
        local emailDisplay = #self.emailText == 0 and "your@email.com" or self.emailText
        lg.print(emailDisplay, fieldX + textPad, textCY(Fonts.small, emailY, fieldH))
        self._emailRect = {x = fieldX, y = emailY, w = fieldW, h = fieldH}

        -- Password field
        local pwY = emailY + fieldH + 18 * sc
        lg.setFont(Fonts.small)
        lg.setColor(0.65, 0.65, 0.7, 1)
        lg.print("Password", fieldX, pwY - Fonts.small:getHeight() - labelGap)

        local pwActive = (self.activeField == "password")
        lg.setColor(pwActive and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
        roundedRect(fieldX, pwY, fieldW, fieldH, 5, sc)
        lg.setColor(pwActive and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
        roundedRectLine(fieldX, pwY, fieldW, fieldH, 5, sc, 2 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(#self.passwordText == 0 and {0.4, 0.4, 0.45, 1} or {1, 1, 1, 1})
        local pwDisplay = #self.passwordText == 0 and "password" or string.rep("*", #self.passwordText)
        lg.print(pwDisplay, fieldX + textPad, textCY(Fonts.small, pwY, fieldH))
        self._passwordRect = {x = fieldX, y = pwY, w = fieldW, h = fieldH}

        -- Recover button
        local canSubmit = #self.emailText > 0 and #self.passwordText > 0
        local subBtnW = 180 * sc
        local subBtnH = 54 * sc
        local subBtnX = cx - subBtnW / 2
        local subBtnY = pwY + fieldH + 30 * sc
        if canSubmit then
            lg.setColor(0.15, 0.35, 0.55, 1)
            roundedRect(subBtnX, subBtnY, subBtnW, subBtnH, 8, sc)
            lg.setColor(0.25, 0.55, 0.75, 1)
            roundedRectLine(subBtnX, subBtnY, subBtnW, subBtnH, 8, sc, 2 * sc)
        else
            lg.setColor(0.12, 0.12, 0.18, 1)
            roundedRect(subBtnX, subBtnY, subBtnW, subBtnH, 8, sc)
            lg.setColor(0.22, 0.22, 0.30, 1)
            roundedRectLine(subBtnX, subBtnY, subBtnW, subBtnH, 8, sc, 2 * sc)
        end
        lg.setFont(Fonts.medium)
        lg.setColor(canSubmit and {1, 1, 1, 1} or {0.4, 0.4, 0.45, 1})
        lg.printf("Recover", subBtnX, textCY(Fonts.medium, subBtnY, subBtnH), subBtnW, 'center')
        self._submitBtnRect = canSubmit and {x = subBtnX, y = subBtnY, w = subBtnW, h = subBtnH} or nil

        -- Back link
        local backW = 160 * sc
        local backH = 30 * sc
        local backX = cx - backW / 2
        local backY = subBtnY + subBtnH + 14 * sc
        lg.setFont(Fonts.small)
        lg.setColor(0.5, 0.5, 0.6, 1)
        lg.printf("< Back", backX, textCY(Fonts.small, backY, backH), backW, 'center')
        self._backBtnRect = {x = backX, y = backY, w = backW, h = backH}
    end

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end

        if self.mode == "restore" then
            -- Back button
            if self._backBtnRect then
                local r = self._backBtnRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    self.mode           = "register"
                    self.activeField    = "name"
                    self._restoreStatus = nil
                    self.emailText      = ""
                    self.passwordText   = ""
                    love.keyboard.setTextInput(false)
                    return
                end
            end
            -- Email field
            if self._emailRect then
                local r = self._emailRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    self.activeField = "email"
                    love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                    return
                end
            end
            -- Password field
            if self._passwordRect then
                local r = self._passwordRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    self.activeField = "password"
                    love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                    return
                end
            end
            -- Recover button
            if self._submitBtnRect then
                local r = self._submitBtnRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    AudioManager.playTap()
                    love.keyboard.setTextInput(false)
                    self:doRestore()
                    return
                end
            end
            self.activeField = nil
            love.keyboard.setTextInput(false)
            return
        end

        -- Register mode
        if self._nameRect then
            local r = self._nameRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.activeField = "name"
                self.status = "ready"
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                return
            end
        end

        if self._playBtnRect then
            local r = self._playBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.playTap()
                love.keyboard.setTextInput(false)
                self:doSubmit()
                return
            end
        end

        if self._restoreBtnRect then
            local r = self._restoreBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.mode           = "restore"
                self.activeField    = "email"
                self._restoreStatus = nil
                love.keyboard.setTextInput(true)
                return
            end
        end

        self.activeField = nil
        love.keyboard.setTextInput(false)
    end

    function self:touchpressed(_, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:textinput(t)
        if self.mode == "restore" then
            if self.activeField == "email" then
                if #self.emailText < 128 and t:match("^[%g]$") then
                    self.emailText = self.emailText .. t
                end
            elseif self.activeField == "password" then
                if #self.passwordText < 128 and t:match("^[%g]$") then
                    self.passwordText = self.passwordText .. t
                end
            end
            return
        end

        if self.activeField ~= "name" then return end
        if #self.nameText >= MAX_NAME_LEN then return end
        if t:match("^[%w_]+$") then
            self.nameText = self.nameText .. t
        end
    end

    function self:keypressed(key)
        if self.mode == "restore" then
            if key == "backspace" then
                if self.activeField == "email" then
                    self.emailText = self.emailText:sub(1, -2)
                elseif self.activeField == "password" then
                    self.passwordText = self.passwordText:sub(1, -2)
                end
            elseif key == "tab" then
                self.activeField = (self.activeField == "email") and "password" or "email"
            elseif key == "return" or key == "kpenter" then
                if self.activeField == "email" then
                    self.activeField = "password"
                else
                    self:doRestore()
                end
            elseif key == "escape" then
                self.mode        = "register"
                self.activeField = "name"
                love.keyboard.setTextInput(false)
            end
            return
        end

        if key == "escape" then
            self.activeField = nil
            love.keyboard.setTextInput(false)
            return
        end

        if self.activeField ~= "name" then return end

        if key == "backspace" then
            self.nameText = self.nameText:sub(1, -2)
        elseif key == "return" or key == "kpenter" then
            if #self.nameText > 0 then
                love.keyboard.setTextInput(false)
                self:doSubmit()
            end
        end
    end

    function self:doSubmit()
        if not self.client or self.status == "connecting" then return end

        self.status = "connecting"
        self.statusMessage = "Creating your profile..."
        self.client:send("register_device", {
            username  = self.nameText,
            device_id = _G.DeviceId or ""
        })
    end

    function self:doRestore()
        if not self.client or self.status == "connecting" then return end
        local email = self.emailText:match("^%s*(.-)%s*$"):lower()
        if not email:match("^[^@]+@[^@]+%.[^@]+$") then
            self._restoreStatus = "Invalid email address"
            return
        end
        if #self.passwordText < 1 then
            self._restoreStatus = "Enter your password"
            return
        end
        self._restoreStatus  = nil
        self.status          = "connecting"
        self.statusMessage   = "Restoring account..."
        self.client:send("login_with_email", {
            email     = email,
            password  = self.passwordText,
            device_id = _G.DeviceId or ""
        })
    end

    return self
end

return NameEntryScreen
