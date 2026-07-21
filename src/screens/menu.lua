-- Mus Online – Main Menu Screen
-- Single battle screen: PLAY (public matchmaking) / SANDBOX / Private room toggle,
-- with a left-side ranking button that opens the leaderboard popup.

local Screen         = require('lib.screen')
local Constants      = require('src.constants')
local SocketManager  = require('src.socket_manager')
local GameSettings   = require('src.game_settings')
local Locale         = require('src.locale')
local json           = require('lib.json')

local MenuScreen = {}

function MenuScreen.new()
    local self = Screen.new()

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init(entering)
        -- Press tracking (tap detection; no swipe/panels anymore)
        self.pressX    = 0
        self.pressY    = 0
        self.isPressed = false
        self.hasMoved  = false
        self.MOVE_CANCEL = 16   -- px of movement that cancels a button tap

        -- Ranking / leaderboard icon (left side of the screen)
        self.rankIcon = love.graphics.newImage('src/assets/ui/ranking.png')
        self.rankIcon:setFilter('nearest', 'nearest')

        -- Rules icon (mirrors the ranking button; battle sprite as placeholder art)
        self.rulesIcon = love.graphics.newImage('src/assets/ui/battle.png')
        self.rulesIcon:setFilter('nearest', 'nearest')

        -- Currency strip icon (header coin counter)
        self.goldIcon = love.graphics.newImage('src/assets/ui/gold.png')
        self.goldIcon:setFilter('nearest', 'nearest')

        -- Settings overlay
        self.showSettings         = false
        self._settingsBtnRect     = nil
        self._settingsMusicRect   = nil
        self._settingsSFXRect     = nil
        self._settingsLangRects   = nil
        self._settingsGodModeRect = nil
        self._settingsTitleRect   = nil
        self._settingsPanelRect   = nil
        self._settingsTitleTaps    = 0
        self._settingsTitleLastTap = 0
        self._showGodModeRow      = false

        -- Email Backup overlay (inside settings)
        self._settingsEmailRect    = nil
        self._emailInputRect       = nil
        self._passwordInputRect    = nil
        self._emailSaveBtnRect     = nil
        self._emailCancelBtnRect   = nil
        self._showEmailForm        = false
        self._emailText            = ""
        self._passwordText         = ""
        self._emailActiveField     = nil
        self._emailFormStatus      = nil
        self._emailFormStatusTimer = 0

        -- Hit-rect caches (rebuilt each draw, stored in screen coords)
        self._playBtnRect     = nil
        self._sandboxBtnRect  = nil
        self._roomToggleRect  = nil
        self._rankBtnRect     = nil
        self._rulesBtnRect    = nil

        -- Transient notice toast
        self._notice      = nil
        self._noticeTimer = 0

        -- Reconnection state
        self._reconnectHandle = nil
        self._reconnecting    = false

        -- Socket callback refs (for cleanup)
        self._cb_currencyUpdate   = nil
        self._cb_disconnect       = nil
        self._cb_forcedLogout     = nil
        self._cb_onlineCount      = nil
        self._cb_leaderboard      = nil
        self._cb_linkEmailSuccess = nil
        self._cb_linkEmailFailed  = nil

        -- Register socket handlers
        self:registerSocketHandlers()

        -- Exit transition animation (header slides up)
        -- direction: 1 = exit (0→1), -1 = enter (1→0)
        if entering then
            self._exitAnim = { active = true, progress = 1, duration = 0.28, callback = nil, direction = -1 }
        else
            self._exitAnim = { active = false, progress = 0, duration = 0.28, callback = nil, direction = 1 }
        end

        love.keyboard.setKeyRepeat(true)

        -- Start background music when player lands on menu
        AudioManager.playMusic()
        AudioManager.setBattleMode(false)

        -- Scrolling ticker stripe (one message at a time, with pause between).
        -- Rebuilt from Locale on each pick so a mid-session language switch takes.
        self._tickerMessages   = self:tickerMessages()
        self._tickerCurrentMsg = nil
        self._tickerLastIdx    = nil
        self._tickerMsgPx      = 0
        self._tickerOffset     = 0
        self._tickerState      = "waiting"
        self._tickerWaitTimer  = 1.0

        -- Button spring physics (Balatro squish/bounce)
        self._playSpring     = { scale = 1.0, vel = 0.0, pressed = false }
        self._sbtnSpring     = { scale = 1.0, vel = 0.0, pressed = false }
        self._roomSpring     = { scale = 1.0, vel = 0.0, pressed = false }
        self._rankSpring     = { scale = 1.0, vel = 0.0, pressed = false }
        self._rulesBtnSpring = { scale = 1.0, vel = 0.0, pressed = false }
        self._settingsSpring = { scale = 1.0, vel = 0.0, pressed = false }

        -- Online player count
        self._onlineCount     = nil  -- nil until first response
        self._onlinePollTimer = 30   -- start at max so first poll fires immediately

        -- Leaderboard popup
        self._showLeaderboard    = false  -- logical open state (drives fetch + input)
        self._leaderboard        = nil   -- array of {username, trophies} once fetched
        self._leaderboardLoading = false
        self._leaderboardFetched = false -- reset when popup closes to refresh next open
        self._lbScale            = 0     -- animated pop scale (0 = hidden)
        self._lbVel              = 0
        self._lbPanelRect        = nil
        self._lbCloseRect        = nil

        -- Settings panel pop-in / shrink-out (same effect as the leaderboard)
        self._settingsScale      = 0     -- animated pop scale (0 = hidden)
        self._settingsPopVel     = 0

        -- Rules popup (game-mode settings: 4/8 kings · emotes · best-of)
        self._showRules       = false
        self._rulesScale      = 0
        self._rulesVel        = 0
        self._rulesPanelRect  = nil
        self._rulesCloseRect  = nil
        self._rulesReyesRects = nil   -- { [false]=rect, [true]=rect }
        self._rulesEmotesRect = nil
        self._rulesBestRects  = nil   -- { [1]=rect, [3]=rect, [5]=rect }

        -- Private room state
        self._privateMode   = false  -- true → code input visible, PLAY joins private
        self._roomKeyText   = ""
        self._roomKeyActive = false  -- text input focused
        self._roomKeyRect   = nil
        self._cursorTimer   = 0
    end

    function self:tickerMessages()
        return {
            Locale.t("menu.ticker1"),
            Locale.t("menu.ticker2"),
            Locale.t("menu.ticker3"),
            Locale.t("menu.ticker4"),
            Locale.t("menu.ticker5"),
        }
    end

    function self:registerSocketHandlers()
        if not _G.GameSocket then
            print("[MENU] WARNING: _G.GameSocket is nil, no handlers registered")
            return
        end

        self._cb_currencyUpdate = _G.GameSocket:on("currency_update", function(data)
            if _G.PlayerData then
                if data.gold    ~= nil then _G.PlayerData.gold    = data.gold    end
                if data.gems    ~= nil then _G.PlayerData.gems    = data.gems    end
                if data.xp      ~= nil then _G.PlayerData.xp      = data.xp      end
                if data.level   ~= nil then _G.PlayerData.level   = data.level   end
                if data.unlocks ~= nil then _G.PlayerData.unlocks = data.unlocks end
            end
        end)

        self._cb_disconnect = _G.GameSocket:on("disconnect", function()
            print("[MENU] Socket disconnected, will reconnect on next action")
        end)

        self._cb_forcedLogout = _G.GameSocket:on("forced_logout", function(data)
            print("[MENU] Forced logout: " .. tostring(data and data.reason))
            love.filesystem.remove("session.dat")
            _G.GameSocket = nil
            _G.PlayerData = nil
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('loading')
        end)

        self._cb_onlineCount = _G.GameSocket:on("online_count", function(data)
            self._onlineCount = data.count
        end)

        self._cb_leaderboard = _G.GameSocket:on("leaderboard_data", function(data)
            self._leaderboard = data.players
            self._leaderboardLoading = false
        end)

        self._cb_linkEmailSuccess = _G.GameSocket:on("link_email_success", function()
            if _G.PlayerData then _G.PlayerData.hasEmailBackup = true end
            -- Persist so next launch shows "Linked" without waiting for server
            local raw = love.filesystem.read("session.dat")
            if raw then
                local ok2, sess = pcall(json.decode, raw)
                if ok2 and sess then
                    sess.hasEmailBackup = true
                    love.filesystem.write("session.dat", json.encode(sess))
                end
            end
            self._showEmailForm        = false
            self._emailFormStatus      = "ok"
            self._emailFormStatusTimer = 2.0
            self._emailText            = ""
            self._passwordText         = ""
            self._emailActiveField     = nil
            love.keyboard.setTextInput(false)
        end)

        self._cb_linkEmailFailed = _G.GameSocket:on("link_email_failed", function(data)
            local reason = (data and data.reason) or "failed"
            local msgs = {
                invalid_email      = "settings.err_invalid_email",
                password_too_short = "settings.err_short_pw",
                email_taken        = "settings.err_email_taken",
                not_authenticated  = "settings.err_not_auth",
            }
            self._emailFormStatus      = Locale.t(msgs[reason] or "settings.err_save_failed")
            self._emailFormStatusTimer = 3.0
        end)
    end

    function self:removeSocketHandlers()
        if _G.GameSocket then
            if self._cb_currencyUpdate    then _G.GameSocket:removeCallback(self._cb_currencyUpdate) end
            if self._cb_disconnect        then _G.GameSocket:removeCallback(self._cb_disconnect) end
            if self._cb_forcedLogout      then _G.GameSocket:removeCallback(self._cb_forcedLogout) end
            if self._cb_onlineCount       then _G.GameSocket:removeCallback(self._cb_onlineCount) end
            if self._cb_leaderboard       then _G.GameSocket:removeCallback(self._cb_leaderboard) end
            if self._cb_linkEmailSuccess  then _G.GameSocket:removeCallback(self._cb_linkEmailSuccess) end
            if self._cb_linkEmailFailed   then _G.GameSocket:removeCallback(self._cb_linkEmailFailed) end
        end
        self._cb_currencyUpdate    = nil
        self._cb_disconnect        = nil
        self._cb_forcedLogout      = nil
        self._cb_onlineCount       = nil
        self._cb_leaderboard       = nil
        self._cb_linkEmailSuccess  = nil
        self._cb_linkEmailFailed   = nil
    end

    function self:startReconnect()
        if self._reconnecting then return end
        self._reconnecting = true
        print("[MENU] Starting socket reconnection...")
        self._reconnectHandle = SocketManager.reconnect(
            function()  -- onSuccess
                print("[MENU] Reconnected successfully")
                self._reconnecting    = false
                self._reconnectHandle = nil
                self:registerSocketHandlers()
            end,
            function(reason)  -- onFailure
                print("[MENU] Reconnect failed: " .. tostring(reason))
                self._reconnecting    = false
                self._reconnectHandle = nil
                love.filesystem.remove("session.dat")
                _G.GameSocket = nil
                _G.PlayerData = nil
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('loading')
            end
        )
    end

    function self:focus(hasFocus)
        if hasFocus then
            -- Returning from background: check socket health
            if _G.GameSocket and not _G.GameSocket:isConnected() and not self._reconnecting then
                print("[MENU] Socket lost while backgrounded, reconnecting...")
                self:startReconnect()
            end
        end
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        love.keyboard.setTextInput(false)
        self:removeSocketHandlers()
    end

    -- ── update ──────────────────────────────────────────────────────────────

    function self:update(dt)
        dt = math.min(dt, 1/30)  -- cap spikes from app backgrounding

        -- Exit/enter transition animation
        if self._exitAnim.active then
            local dir = self._exitAnim.direction or 1
            self._exitAnim.progress = self._exitAnim.progress + dir * dt / self._exitAnim.duration
            if dir == 1 then
                self._exitAnim.progress = math.min(1, self._exitAnim.progress)
                if self._exitAnim.progress >= 1 and self._exitAnim.callback then
                    local cb = self._exitAnim.callback
                    self._exitAnim.callback = nil
                    if cb then cb() end
                    return
                end
            else
                self._exitAnim.progress = math.max(0, self._exitAnim.progress)
                if self._exitAnim.progress <= 0 then
                    self._exitAnim.active = false
                end
            end
        end

        -- Keep socket connection alive, or reconnect if dead
        if self._reconnecting and self._reconnectHandle then
            SocketManager.updateReconnect(self._reconnectHandle, dt)
        elseif _G.GameSocket then
            if _G.GameSocket:isConnected() then
                local ok, err = pcall(function() _G.GameSocket:update() end)
                if not ok then
                    print("[MENU] Socket error, reconnecting: " .. tostring(err))
                    _G.GameSocket = nil
                    self:startReconnect()
                end
            elseif not self._reconnecting then
                self:startReconnect()
            end
        end

        -- Leaderboard fetch when popup is open
        if self._showLeaderboard then
            if not self._leaderboardFetched and _G.GameSocket and _G.GameSocket:isConnected() then
                self._leaderboardFetched = true
                self._leaderboardLoading = true
                _G.GameSocket:send("get_leaderboard", {})
            end
        else
            self._leaderboardFetched = false  -- reset so it refreshes next open
        end

        -- Cursor blink timer for room key input
        self._cursorTimer = (self._cursorTimer or 0) + dt

        -- Online count polling (every 30s)
        if _G.GameSocket and _G.GameSocket:isConnected() then
            self._onlinePollTimer = self._onlinePollTimer + dt
            if self._onlinePollTimer >= 30 then
                self._onlinePollTimer = 0
                _G.GameSocket:send("get_online_count", {})
            end
        end

        -- Notice toast timer
        if self._noticeTimer > 0 then
            self._noticeTimer = self._noticeTimer - dt
            if self._noticeTimer <= 0 then
                self._notice      = nil
                self._noticeTimer = 0
            end
        end

        if self._emailFormStatusTimer > 0 then
            self._emailFormStatusTimer = self._emailFormStatusTimer - dt
            if self._emailFormStatusTimer <= 0 then
                self._emailFormStatusTimer = 0
                if self._emailFormStatus ~= "saving" then
                    self._emailFormStatus = nil
                end
            end
        end

        -- Ticker: one message scrolls across, then pauses before the next
        local tickerW = Constants.GAME_WIDTH
        local tickerSpeed = 60 * Constants.SCALE
        local TICKER_PAUSE = 2.5

        if self._tickerState == "scrolling" then
            self._tickerOffset = self._tickerOffset + tickerSpeed * dt
            if self._tickerOffset >= tickerW + self._tickerMsgPx then
                self._tickerState     = "waiting"
                self._tickerWaitTimer = TICKER_PAUSE
            end
        elseif self._tickerState == "waiting" then
            self._tickerWaitTimer = self._tickerWaitTimer - dt
            if self._tickerWaitTimer <= 0 then
                self._tickerMessages = self:tickerMessages()
                local msgs = self._tickerMessages
                local idx  = math.random(#msgs)
                if #msgs > 1 then
                    while idx == self._tickerLastIdx do
                        idx = math.random(#msgs)
                    end
                end
                self._tickerLastIdx    = idx
                self._tickerCurrentMsg = msgs[idx]
                self._tickerMsgPx      = Fonts.small:getWidth(self._tickerCurrentMsg)
                self._tickerOffset     = 0
                self._tickerState      = "scrolling"
            end
        end

        -- Button spring physics (underdamped: k=480, d=18 → overshoot ~1.05)
        local function updateSpring(sp, dt2)
            local target = sp.pressed and 0.93 or 1.0
            local accel  = -480 * (sp.scale - target) - 18 * sp.vel
            sp.vel   = sp.vel   + accel * dt2
            sp.scale = sp.scale + sp.vel  * dt2
            sp.scale = math.max(0.85, math.min(1.12, sp.scale))
        end
        updateSpring(self._playSpring, dt)
        updateSpring(self._sbtnSpring, dt)
        updateSpring(self._roomSpring, dt)
        updateSpring(self._rankSpring, dt)
        updateSpring(self._rulesBtnSpring, dt)
        updateSpring(self._settingsSpring, dt)

        -- Leaderboard popup pop-in / shrink-out (underdamped → satisfying overshoot)
        local lbTarget = self._showLeaderboard and 1 or 0
        local lbAccel  = -460 * (self._lbScale - lbTarget) - 22 * self._lbVel
        self._lbVel   = self._lbVel   + lbAccel * dt
        self._lbScale = self._lbScale + self._lbVel * dt
        if lbTarget == 0 and self._lbScale <= 0.001 then
            self._lbScale = 0
            self._lbVel   = 0
        elseif self._lbScale < 0 then
            self._lbScale = 0
        end

        -- Settings panel pop-in / shrink-out (underdamped → satisfying overshoot)
        local stTarget = self.showSettings and 1 or 0
        local stAccel  = -460 * (self._settingsScale - stTarget) - 22 * self._settingsPopVel
        self._settingsPopVel = self._settingsPopVel + stAccel * dt
        self._settingsScale  = self._settingsScale  + self._settingsPopVel * dt
        if stTarget == 0 and self._settingsScale <= 0.001 then
            self._settingsScale  = 0
            self._settingsPopVel = 0
        elseif self._settingsScale < 0 then
            self._settingsScale = 0
        end

        -- Rules popup pop-in / shrink-out (same underdamped feel)
        local rlTarget = self._showRules and 1 or 0
        local rlAccel  = -460 * (self._rulesScale - rlTarget) - 22 * self._rulesVel
        self._rulesVel   = self._rulesVel   + rlAccel * dt
        self._rulesScale = self._rulesScale + self._rulesVel * dt
        if rlTarget == 0 and self._rulesScale <= 0.001 then
            self._rulesScale = 0
            self._rulesVel   = 0
        elseif self._rulesScale < 0 then
            self._rulesScale = 0
        end
    end

    -- ── ticker stripe ────────────────────────────────────────────────────────

    function self:drawTickerStripe(W, sc)
        local lg      = love.graphics
        local stripeY = math.floor(75 * sc + Constants.MENU_CONTENT_PUSH)
        local stripeH = math.floor(36 * sc)

        -- Background
        lg.setColor(0.133, 0.133, 0.157, 1)
        lg.rectangle('fill', 0, stripeY, W, stripeH)

        -- Separator lines
        lg.setColor(0.463, 0.529, 0.671, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(0, stripeY, W, stripeY)
        lg.line(0, stripeY + stripeH, W, stripeY + stripeH)

        -- Draw current message scrolling right-to-left
        if self._tickerCurrentMsg and self._tickerState == "scrolling" then
            lg.setScissor(0, stripeY, W, stripeH)
            lg.setFont(Fonts.small)
            lg.setColor(0.875, 0.902, 0.878, 1)
            local textY = math.floor(stripeY + (stripeH - (Fonts.small:getAscent() - Fonts.small:getDescent())) / 2)
            lg.print(self._tickerCurrentMsg, math.floor(W - self._tickerOffset), textY)
            lg.setScissor()
        end
    end

    -- ── draw helpers ────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    -- Vertically centre text in a box using actual glyph bounds (excludes leading)
    local function textCY(font, boxY, boxH)
        return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
    end

    function self:drawGroupHeader(x, y, w, h, name, sc)
        local lg = love.graphics
        lg.setColor(0.267, 0.290, 0.396, 1)
        lg.rectangle("fill", x, y, w, h, 4 * sc, 4 * sc)
        lg.setColor(0.757, 0.482, 0.361, 1)
        lg.rectangle("fill", x, y, 4 * sc, h, 2 * sc, 2 * sc)
        lg.setColor(0.463, 0.529, 0.671, 0.5)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(x, y + 1, x + w, y + 1)
        lg.setColor(0.133, 0.133, 0.157, 0.8)
        lg.line(x, y + h - 1, x + w, y + h - 1)
        lg.setFont(Fonts.medium)
        lg.setColor(0.875, 0.902, 0.878, 1)
        lg.print(name, x + 14 * sc, textCY(Fonts.medium, y, h))
    end

    -- Draw a Balatro-style floating button; returns the hit rect covering the float range.
    -- opts: { label, x, y, w, h, spring, faceColor, borderColor, font, idle }
    local function drawFloatButton(opts, sc)
        local lg       = love.graphics
        local bx, by   = opts.x, opts.y
        local w, h     = opts.w, opts.h
        local maxFloat = math.floor(6 * sc)
        local shadowH  = math.floor(6 * sc)
        local s        = opts.spring.scale
        local floatOff = math.floor(maxFloat * math.max(0, (s - 0.93) / 0.07))
        local idleBob, idleRot = 0, 0
        if opts.idle ~= false then
            local t = love.timer.getTime()
            idleBob = math.sin(t * 1.8) * 2 * sc
            idleRot = math.sin(t * 1.3) * 0.012
        end
        local drawY = by - floatOff + math.floor(idleBob)

        -- Shadow (static at anchor — button floats above it)
        lg.setColor(0.133, 0.133, 0.157, 1)
        roundedRect(bx + math.floor(2 * sc), by + shadowH, w, h, 8, sc)

        -- Face: pivot at center, rotate then scale
        local pivX = bx + w / 2
        local pivY = drawY + h / 2
        lg.push()
        lg.translate(pivX, pivY)
        lg.rotate(idleRot)
        lg.scale(s, s)
        local fc = opts.faceColor
        lg.setColor(fc[1], fc[2], fc[3], 1)
        roundedRect(-w / 2, -h / 2, w, h, 8, sc)
        local bc = opts.borderColor
        lg.setColor(bc[1], bc[2], bc[3], 1)
        roundedRectLine(-w / 2, -h / 2, w, h, 8, sc, 2 * sc)
        lg.setFont(opts.font)
        lg.setColor(1, 1, 1, 1)
        lg.printf(opts.label, -w / 2, textCY(opts.font, -h / 2, h), w, 'center')
        lg.pop()

        return { x = bx, y = by - maxFloat, w = w, h = h + maxFloat }
    end

    function self:drawBattlePanel(W, H, sc)
        local lg    = love.graphics
        local cx    = W / 2

        local btnW    = 240 * sc
        local playH   = 112 * sc
        local sbtnH   = 32  * sc
        local btnX    = cx - btnW / 2
        local shadowH = math.floor(6 * sc)

        -- PLAY anchored below centre, with the stacked buttons under it
        local btnY = math.floor(H * 0.65)

        -- Shared anchor: the top of the private code-input row. The rules
        -- summary sits above this line so the two coexist in private mode.
        local inputH   = math.floor(48 * sc)
        local labelH   = Fonts.small:getHeight()
        local inputTop = math.floor(btnY - labelH - 10 * sc - inputH - 12 * sc)

        -- ── Code input (private mode only) ─────────────────────────────────────
        if self._privateMode then
            local inputW = btnW
            local inputX = btnX
            local inputY = inputTop

            if self._roomKeyActive then
                lg.setColor(0.133, 0.133, 0.157, 1)
            else
                lg.setColor(0.267, 0.290, 0.396, 1)
            end
            lg.rectangle('fill', inputX, inputY, inputW, inputH, 4 * sc, 4 * sc)
            if self._roomKeyActive then
                lg.setColor(0.875, 0.902, 0.878, 0.9)
            else
                lg.setColor(0.757, 0.482, 0.361, 0.5)
            end
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.rectangle('line', inputX, inputY, inputW, inputH, 4 * sc, 4 * sc)

            lg.setFont(Fonts.medium)
            local cursor = (self._roomKeyActive and math.floor(self._cursorTimer * 2) % 2 == 0) and "|" or ""
            if self._roomKeyText == "" and not self._roomKeyActive then
                lg.setColor(0.4, 0.4, 0.45, 1)
                lg.printf(Locale.t("menu.enter_code"), inputX, textCY(Fonts.medium, inputY, inputH), inputW, 'center')
            else
                lg.setColor(0.875, 0.902, 0.878, 1)
                local txt = self._roomKeyText .. cursor
                local tw  = Fonts.medium:getWidth(txt)
                lg.print(txt, inputX + math.floor((inputW - tw) / 2), textCY(Fonts.medium, inputY, inputH))
            end
            self._roomKeyRect = { x = inputX, y = inputY, w = inputW, h = inputH }
        else
            self._roomKeyRect = nil
        end

        -- ── Currently-selected rules summary (edit via the rules button) ───────
        -- Positioned above the private-input row so both show together.
        do
            local capH   = Fonts.tiny:getHeight()
            local valH   = Fonts.small:getHeight()
            local blockH = capH + valH + math.floor(4 * sc)
            local sumY   = inputTop - math.floor(14 * sc) - blockH
            lg.setFont(Fonts.tiny)
            lg.setColor(0.757, 0.482, 0.361, 1)
            lg.printf(Locale.t("menu.rules_caption"), 0, sumY, W, 'center')
            lg.setFont(Fonts.small)
            lg.setColor(0.875, 0.902, 0.878, 1)
            lg.printf(GameSettings.summary(), 0, sumY + capH + math.floor(4 * sc), W, 'center')
        end

        -- ── Online count label above PLAY (hidden) ────────────────────────────
        -- local countLabel = self._onlineCount and ("Players online: " .. self._onlineCount) or "Players online: ..."
        -- lg.setFont(Fonts.small)
        -- lg.setColor(0.875, 0.902, 0.878, 0.85)
        -- lg.printf(countLabel, btnX, btnY - Fonts.small:getHeight() - 8 * sc, btnW, 'center')

        -- ── PLAY button (joins the private room when in private mode) ──────────
        self._playBtnRect = drawFloatButton({
            label = Locale.t("menu.play"), x = btnX, y = btnY, w = btnW, h = playH,
            spring = self._playSpring, font = Fonts.large,
            faceColor = {0.757, 0.482, 0.361}, borderColor = {0.875, 0.902, 0.878},
        }, sc)

        -- ── SANDBOX button ─────────────────────────────────────────────────────
        local sbtnY = math.floor(btnY + playH + shadowH + 14 * sc)
        self._sandboxBtnRect = drawFloatButton({
            label = Locale.t("menu.sandbox"), x = btnX, y = sbtnY, w = btnW, h = sbtnH,
            spring = self._sbtnSpring, font = Fonts.small, idle = false,
            faceColor = {0.522, 0.267, 0.290}, borderColor = {0.522, 0.267, 0.290},
        }, sc)

        -- ── PRIVATE / PUBLIC ROOM toggle button ────────────────────────────────
        local roomY = math.floor(sbtnY + sbtnH + shadowH + 12 * sc)
        local roomLabel = self._privateMode and Locale.t("menu.public_room") or Locale.t("menu.private_room")
        self._roomToggleRect = drawFloatButton({
            label = roomLabel, x = btnX, y = roomY, w = btnW, h = sbtnH,
            spring = self._roomSpring, font = Fonts.small, idle = false,
            faceColor = {0.267, 0.290, 0.396}, borderColor = {0.463, 0.529, 0.671},
        }, sc)

        -- ── Ranking button (top-left, just under the ticker stripe) ─────────────
        local rankSize    = math.floor(84 * sc)
        local tickerBottom = math.floor(75 * sc + Constants.MENU_CONTENT_PUSH) + math.floor(36 * sc)
        local rankX       = math.floor(12 * sc + Constants.SAFE_INSET_LEFT)
        local rankY       = math.floor(tickerBottom + 12 * sc)
        local rs       = self._rankSpring.scale
        lg.push()
        lg.translate(rankX + rankSize / 2, rankY + rankSize / 2)
        lg.scale(rs, rs)
        lg.translate(-(rankX + rankSize / 2), -(rankY + rankSize / 2))
        lg.setColor(0.133, 0.133, 0.157, 1)
        roundedRect(rankX, rankY, rankSize, rankSize, 8, sc)
        lg.setColor(0.463, 0.529, 0.671, 1)
        roundedRectLine(rankX, rankY, rankSize, rankSize, 8, sc, 2 * sc)
        -- Icon only (integer pixel scale, centred)
        local iw    = self.rankIcon:getWidth()
        local ih    = self.rankIcon:getHeight()
        local pixSc = math.max(2, math.floor((rankSize * 0.72) / iw))
        local ix    = math.floor(rankX + (rankSize - iw * pixSc) / 2)
        local iy    = math.floor(rankY + (rankSize - ih * pixSc) / 2)
        lg.setColor(1, 1, 1, 1)
        lg.draw(self.rankIcon, ix, iy, 0, pixSc, pixSc)
        lg.pop()
        self._rankBtnRect = { x = rankX, y = rankY, w = rankSize, h = rankSize }

        -- ── Rules button (mirrors the ranking button, top-right at same height) ─
        local rulesX = math.floor(W - rankSize - 12 * sc - Constants.SAFE_INSET_RIGHT)
        local rulesY = rankY
        local rls    = self._rulesBtnSpring.scale
        lg.push()
        lg.translate(rulesX + rankSize / 2, rulesY + rankSize / 2)
        lg.scale(rls, rls)
        lg.translate(-(rulesX + rankSize / 2), -(rulesY + rankSize / 2))
        lg.setColor(0.133, 0.133, 0.157, 1)
        roundedRect(rulesX, rulesY, rankSize, rankSize, 8, sc)
        lg.setColor(0.463, 0.529, 0.671, 1)
        roundedRectLine(rulesX, rulesY, rankSize, rankSize, 8, sc, 2 * sc)
        local riw  = self.rulesIcon:getWidth()
        local rih  = self.rulesIcon:getHeight()
        local rpix = math.max(2, math.floor((rankSize * 0.72) / riw))
        local rix  = math.floor(rulesX + (rankSize - riw * rpix) / 2)
        local riy  = math.floor(rulesY + (rankSize - rih * rpix) / 2)
        lg.setColor(1, 1, 1, 1)
        lg.draw(self.rulesIcon, rix, riy, 0, rpix, rpix)
        lg.pop()
        self._rulesBtnRect = { x = rulesX, y = rulesY, w = rankSize, h = rankSize }

        -- ── Notice toast (centred below the room toggle) ────────────────────────
        if self._noticeTimer > 0 and self._notice then
            lg.setFont(Fonts.small)
            lg.setColor(0.875, 0.902, 0.878, math.min(1, self._noticeTimer))
            lg.printf(self._notice, 0, roomY + sbtnH + shadowH + 16 * sc, W, 'center')
        end
    end

    function self:drawLeaderboardPopup(W, H, sc)
        local lg = love.graphics
        local s  = self._lbScale

        -- Dim backdrop (fades in/out with the pop)
        lg.setColor(0, 0, 0, 0.65 * math.min(1, s))
        lg.rectangle('fill', 0, 0, W, H)

        local panW = math.floor(W * 0.88)
        local hdrH = math.floor(40 * sc)
        local rowH = math.floor(40 * sc)
        local pad  = math.floor(16 * sc)

        -- Fixed body height (server returns a top-5) so the panel never resizes.
        local rows     = self._leaderboard or {}
        local bodyRows = #rows
        local LB_ROWS  = 5
        local bodyH    = LB_ROWS * rowH

        local panH = pad + hdrH + math.floor(6 * sc) + bodyH + pad
        local panX = math.floor((W - panW) / 2)
        local panY = math.floor((H - panH) / 2)
        local brd  = math.max(1, math.floor(2 * sc))

        -- Scale the whole panel around its centre for the pop-in / shrink-out
        lg.push()
        lg.translate(panX + panW / 2, panY + panH / 2)
        lg.scale(s, s)
        lg.translate(-(panX + panW / 2), -(panY + panH / 2))

        -- Panel (background matches the ticker stripe)
        lg.setColor(0.133, 0.133, 0.157, 1)
        roundedRect(panX, panY, panW, panH, 5, sc)
        lg.setColor(0.463, 0.529, 0.671, 1)
        roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

        local innerX = panX + pad
        local innerW = panW - pad * 2
        local y      = panY + pad

        -- Header + close button
        self:drawGroupHeader(innerX, y, innerW, hdrH, Locale.t("menu.leaderboard"), sc)
        local closeSz = math.floor(hdrH * 0.62)
        local closeX  = innerX + innerW - closeSz - math.floor(6 * sc)
        local closeY  = y + math.floor((hdrH - closeSz) / 2)
        lg.setColor(0.522, 0.267, 0.290, 1)
        roundedRect(closeX, closeY, closeSz, closeSz, 4, sc)
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        lg.printf("X", closeX, textCY(Fonts.small, closeY, closeSz), closeSz, 'center')
        self._lbCloseRect = { x = closeX, y = closeY, w = closeSz, h = closeSz }

        y = y + hdrH + math.floor(6 * sc)

        if self._leaderboardLoading then
            lg.setFont(Fonts.small)
            lg.setColor(0.663, 0.733, 0.800, 1)
            lg.printf(Locale.t("common.loading"), panX, y + math.floor(bodyH / 2 - Fonts.small:getHeight() / 2), panW, 'center')
        elseif bodyRows == 0 then
            lg.setFont(Fonts.small)
            lg.setColor(0.663, 0.733, 0.800, 1)
            lg.printf(Locale.t("menu.no_data"), panX, y + math.floor(bodyH / 2 - Fonts.small:getHeight() / 2), panW, 'center')
        else
            for i = 1, math.min(bodyRows, LB_ROWS) do
                local entry = rows[i]
                local ry = y + (i - 1) * rowH
                -- Highlight current player
                if _G.PlayerData and entry.username == _G.PlayerData.username then
                    lg.setColor(0.463, 0.529, 0.671, 0.35)
                    lg.rectangle('fill', innerX, ry, innerW, rowH)
                end
                -- Separator line
                if i > 1 then
                    lg.setColor(0.463, 0.529, 0.671, 1)
                    lg.setLineWidth(1)
                    lg.line(innerX, ry, innerX + innerW, ry)
                end
                -- Rank number (palette tiers for top 3)
                lg.setFont(Fonts.small)
                local rankColor = i == 1 and {0.875, 0.902, 0.878, 1}
                               or i == 2 and {0.757, 0.482, 0.361, 1}
                               or i == 3 and {0.522, 0.267, 0.290, 1}
                               or             {0.506, 0.384, 0.443, 1}
                lg.setColor(rankColor[1], rankColor[2], rankColor[3], rankColor[4])
                lg.print("#" .. i, innerX + math.floor(6 * sc), textCY(Fonts.small, ry, rowH))
                -- Username
                lg.setColor(0.875, 0.902, 0.878, 1)
                lg.print(entry.username, innerX + math.floor(46 * sc), textCY(Fonts.small, ry, rowH))
                -- Trophy count (right-aligned)
                local tStr = Locale.t("common.trophies", entry.trophies or 0)
                local tW   = Fonts.small:getWidth(tStr)
                lg.setColor(0.757, 0.482, 0.361, 1)
                lg.print(tStr, innerX + innerW - tW - math.floor(6 * sc), textCY(Fonts.small, ry, rowH))
            end
        end

        lg.pop()

        self._lbPanelRect = { x = panX, y = panY, w = panW, h = panH }
    end

    function self:drawRulesPopup(W, H, sc)
        local lg = love.graphics
        local s  = self._rulesScale

        -- Dim backdrop
        lg.setColor(0, 0, 0, 0.65 * math.min(1, s))
        lg.rectangle('fill', 0, 0, W, H)

        local panW = math.floor(W * 0.88)
        local hdrH = math.floor(40 * sc)
        local rowH = math.floor(56 * sc)
        local pad  = math.floor(16 * sc)
        local bodyH = 3 * rowH
        local panH = pad + hdrH + math.floor(6 * sc) + bodyH + pad
        local panX = math.floor((W - panW) / 2)
        local panY = math.floor((H - panH) / 2)
        local brd  = math.max(1, math.floor(2 * sc))

        lg.push()
        lg.translate(panX + panW / 2, panY + panH / 2)
        lg.scale(s, s)
        lg.translate(-(panX + panW / 2), -(panY + panH / 2))

        lg.setColor(0.133, 0.133, 0.157, 1)
        roundedRect(panX, panY, panW, panH, 5, sc)
        lg.setColor(0.463, 0.529, 0.671, 1)
        roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

        local innerX = panX + pad
        local innerW = panW - pad * 2
        local y      = panY + pad

        -- Header + close button
        self:drawGroupHeader(innerX, y, innerW, hdrH, Locale.t("rules.title"), sc)
        local closeSz = math.floor(hdrH * 0.62)
        local closeX  = innerX + innerW - closeSz - math.floor(6 * sc)
        local closeY  = y + math.floor((hdrH - closeSz) / 2)
        lg.setColor(0.522, 0.267, 0.290, 1)
        roundedRect(closeX, closeY, closeSz, closeSz, 4, sc)
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        lg.printf("X", closeX, textCY(Fonts.small, closeY, closeSz), closeSz, 'center')
        self._rulesCloseRect = { x = closeX, y = closeY, w = closeSz, h = closeSz }

        y = y + hdrH + math.floor(6 * sc)

        -- Segmented control: draws each option, highlights the selected one,
        -- returns { [value] = rect }.
        local function segmented(label, rowY, options, current)
            local rects = {}
            lg.setFont(Fonts.small)
            lg.setColor(0.757, 0.482, 0.361, 1)
            lg.print(label, innerX + math.floor(4 * sc), textCY(Fonts.small, rowY, math.floor(40 * sc)))

            local n     = #options
            local segH  = math.floor(34 * sc)
            local gap   = math.floor(6 * sc)
            local totalW = math.floor(innerW * 0.52)
            local segW  = math.floor((totalW - gap * (n - 1)) / n)
            local startX = innerX + innerW - totalW
            local segY  = rowY + math.floor((40 * sc - segH) / 2)
            for i, opt in ipairs(options) do
                local sx = startX + (i - 1) * (segW + gap)
                local sel = (opt.value == current)
                if sel then lg.setColor(0.757, 0.482, 0.361, 1) else lg.setColor(0.267, 0.290, 0.396, 1) end
                roundedRect(sx, segY, segW, segH, 4, sc)
                if sel then lg.setColor(0.875, 0.902, 0.878, 1) else lg.setColor(0.463, 0.529, 0.671, 1) end
                roundedRectLine(sx, segY, segW, segH, 4, sc, math.max(1, math.floor(sc)))
                lg.setFont(Fonts.small)
                lg.setColor(sel and {1, 1, 1, 1} or {0.663, 0.733, 0.800, 1})
                lg.printf(opt.text, sx, textCY(Fonts.small, segY, segH), segW, 'center')
                rects[opt.value] = { x = sx, y = segY, w = segW, h = segH }
            end
            return rects
        end

        -- Row 1 — Reyes (4 vs 8 kings)
        self._rulesReyesRects = segmented(Locale.t("rules.kings"), y,
            { { value = false, text = "4" }, { value = true, text = "8" } },
            GameSettings.reyes8)

        -- Row 2 — Emotes (on/off)
        self._rulesEmotesRect = segmented(Locale.t("rules.emotes"), y + rowH,
            { { value = false, text = "OFF" }, { value = true, text = "ON" } },
            GameSettings.emotes)

        -- Row 3 — Sets (best of 1/3/5)
        self._rulesBestRects = segmented(Locale.t("rules.sets"), y + rowH * 2,
            { { value = 1, text = "1" }, { value = 3, text = "3" }, { value = 5, text = "5" } },
            GameSettings.bestOf)

        lg.pop()
        self._rulesPanelRect = { x = panX, y = panY, w = panW, h = panH }
    end

    -- ── draw ────────────────────────────────────────────────────────────────

    function self:draw()
        local lg   = love.graphics
        local W    = Constants.GAME_WIDTH
        local H    = Constants.GAME_HEIGHT
        local sc   = Constants.SCALE

        -- Exit animation: ease-in slide offset (0 → 1)
        local exitT = self._exitAnim.progress
        local exitEase = exitT * exitT  -- quadratic ease-in

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Battle content
        self:drawBattlePanel(W, H, sc)

        -- Scrolling ticker stripe (screen space, fixed above panel content)
        self:drawTickerStripe(W, sc)

        -- Top-left header: player name + trophies + XP bar + settings button
        -- (slides upward during exit animation)
        local headerSlideH = math.floor((80 * sc + H * 0.05) * exitEase)
        lg.push()
        lg.translate(0, -headerSlideH)
        if _G.PlayerData then
            local vPad   = math.floor(5 * sc)
            local edgeX  = math.floor(8 * sc)

            lg.setFont(Fonts.small)
            local numLineH = Fonts.small:getHeight()
            local stripH   = numLineH + vPad * 2
            local stripY   = math.max(math.floor(8 * sc), math.floor(Constants.SAFE_INSET_TOP + 2 * sc))
            local xCur     = edgeX

            -- Player name
            lg.setFont(Fonts.medium)
            local nameStr = _G.PlayerData.username or ""
            local nameW   = Fonts.medium:getWidth(nameStr)
            local nameY   = textCY(Fonts.medium, stripY, stripH)
            lg.setColor(1, 1, 1, 1)
            lg.print(nameStr, xCur, nameY)

            -- Trophies below name, slightly indented
            lg.setFont(Fonts.tiny)
            lg.setColor(0.851, 0.761, 0.467, 0.9)
            lg.print(Locale.t("common.trophies", _G.PlayerData.trophies or 0),
                     xCur + math.floor(4 * sc),
                     stripY + stripH + math.floor(1 * sc))

            xCur = xCur + nameW + math.floor(12 * sc)

            -- Settings "+" button (top-right corner, play-button style)
            local sbW      = stripH
            local sbX      = W - sbW - edgeX
            local sbY      = stripY + 2
            local smaxF    = math.floor(4 * sc)
            local sshad    = math.floor(4 * sc)
            local ssp      = self._settingsSpring
            local sfloatOff = math.floor(smaxF * math.max(0, (ssp.scale - 0.93) / 0.07))
            local t_s      = love.timer.getTime()
            local sidleBob = math.sin(t_s * 1.8 + 0.5) * 0.5 * sc
            local sidleRot = math.sin(t_s * 1.3 + 0.5) * 0.003
            local sdrawY   = sbY - sfloatOff + math.floor(sidleBob)

            self._settingsBtnRect = { x = sbX, y = sbY - smaxF, w = sbW, h = sbW + smaxF }

            -- Shadow
            lg.setColor(0.133, 0.133, 0.157, 1)
            roundedRect(sbX + math.floor(2 * sc), sbY + sshad, sbW, sbW, 8, sc)

            -- Face
            local spivX = sbX + sbW / 2
            local spivY = sdrawY + sbW / 2
            local sbx   = -sbW / 2
            local sby   = -sbW / 2
            lg.push()
            lg.translate(spivX, spivY)
            lg.rotate(sidleRot)
            lg.scale(ssp.scale, ssp.scale)
            lg.setColor(0.267, 0.290, 0.396, 1)
            roundedRect(sbx, sby, sbW, sbW, 8, sc)
            lg.setColor(0.463, 0.529, 0.671, 1)
            roundedRectLine(sbx, sby, sbW, sbW, 8, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.875, 0.902, 0.878, 1)
            lg.printf("+", sbx, textCY(Fonts.small, sby, sbW), sbW, 'center')
            lg.pop()

            -- XP bar: same height as settings button, fills 2/3 of gap; coin counter takes remaining 1/3
            local barGap  = math.floor(8 * sc)
            local barX    = xCur
            local totalW  = sbX - barGap - barX
            local barW    = math.floor(totalW * 2 / 3)
            if barW > 0 then
                local plevel = _G.PlayerData.level or 1
                local pxp    = _G.PlayerData.xp    or 0
                local xpNeed = 30 + math.floor((plevel - 1) / 10) * 5
                local barR   = math.max(1, math.floor(3 * sc))
                local fillW  = math.floor(barW * math.min(pxp / xpNeed, 1))

                lg.setColor(0.267, 0.290, 0.396, 1)
                lg.rectangle('fill', barX, stripY, barW, stripH, barR, barR)
                if fillW > 0 then
                    lg.setColor(0.290, 0.212, 0.235, 1)
                    lg.rectangle('fill', barX, stripY, fillW, stripH, barR, barR)
                end
                lg.setColor(0.463, 0.529, 0.671, 1)
                lg.setLineWidth(math.max(1, math.floor(sc)))
                lg.rectangle('line', barX, stripY, barW, stripH, barR, barR)

                lg.setFont(Fonts.small)
                lg.setColor(0.875, 0.902, 0.878, 1)
                lg.printf(Locale.t("common.level", plevel), barX, textCY(Fonts.small, stripY, stripH), barW, 'center')
            end

            -- Coin counter pill (between XP bar and settings button)
            local coinGap = barGap
            local coinX   = barX + barW + coinGap
            local coinW   = sbX - barGap - coinX
            if coinW > 0 then
                local barR = math.max(1, math.floor(3 * sc))
                lg.setColor(0.267, 0.290, 0.396, 1)
                lg.rectangle('fill', coinX, stripY, coinW, stripH, barR, barR)
                lg.setColor(0.463, 0.529, 0.671, 1)
                lg.setLineWidth(math.max(1, math.floor(sc)))
                lg.rectangle('line', coinX, stripY, coinW, stripH, barR, barR)

                local iconH  = stripH - vPad * 2
                local iconSc = iconH / self.goldIcon:getHeight()
                local iconW  = self.goldIcon:getWidth() * iconSc
                local iconX  = coinX + math.floor(6 * sc)
                local iconY  = stripY + vPad
                lg.setColor(1, 1, 1, 1)
                lg.draw(self.goldIcon, iconX, iconY, 0, iconSc, iconSc)

                local coins  = _G.PlayerData.gold or _G.PlayerData.coins or 0
                lg.setFont(Fonts.small)
                lg.setColor(0.875, 0.902, 0.878, 1)
                local textX  = iconX + iconW + math.floor(4 * sc)
                local textW  = coinX + coinW - textX - math.floor(4 * sc)
                if textW > 0 then
                    lg.printf(tostring(coins), textX, textCY(Fonts.small, stripY, stripH), textW, 'left')
                end
            end
        end
        lg.pop()

        -- Version label
        lg.setFont(Fonts.tiny)
        lg.setColor(1, 1, 1, 0.35)
        lg.print("v1.1", math.floor(4 * sc), math.max(math.floor(4 * sc), math.floor(Constants.SAFE_INSET_TOP)))

        -- Leaderboard popup
        if self._lbScale > 0.001 then
            self:drawLeaderboardPopup(W, H, sc)
        end

        -- Rules popup
        if self._rulesScale > 0.001 then
            self:drawRulesPopup(W, H, sc)
        end

        -- Settings overlay
        if self._settingsScale > 0.001 then
            local s = self._settingsScale

            -- Dim backdrop (fades in/out with the pop)
            lg.setColor(0, 0, 0, 0.65 * math.min(1, s))
            lg.rectangle('fill', 0, 0, W, H)

            -- Panel geometry
            local panW  = math.floor(300 * sc)
            local baseH = 320
            baseH = baseH + 44                                       -- Language row
            if self._showGodModeRow then baseH = baseH + 44 end
            baseH = baseH + 44                                       -- Email Backup row
            if self._showEmailForm  then baseH = baseH + 130 end    -- inline form
            local panH  = math.floor(baseH) * sc
            local panX  = math.floor((W - panW) / 2)
            local panY  = math.floor((H - panH) / 2)
            local brd   = math.max(1, math.floor(2 * sc))

            -- Scale the whole panel around its centre for the pop-in / shrink-out
            lg.push()
            lg.translate(panX + panW / 2, panY + panH / 2)
            lg.scale(s, s)
            lg.translate(-(panX + panW / 2), -(panY + panH / 2))

            -- Panel fill
            lg.setColor(0.267, 0.290, 0.396, 1)
            roundedRect(panX, panY, panW, panH, 5, sc)

            -- Outer border
            lg.setColor(0.463, 0.529, 0.671, 1)
            roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

            -- Bevel: top-left highlight
            local hl = brd + math.max(1, math.floor(sc))
            lg.setColor(0.463, 0.529, 0.671, 0.5)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + hl, panY + panH - hl,
                    panX + hl, panY + hl,
                    panX + panW - hl, panY + hl)

            -- Bevel: bottom-right shadow
            lg.setColor(0.133, 0.133, 0.157, 0.8)
            lg.line(panX + hl, panY + panH - hl,
                    panX + panW - hl, panY + panH - hl,
                    panX + panW - hl, panY + hl)

            -- Compute content block height to centre it vertically in the panel
            local contentHraw = 196
            contentHraw = contentHraw + 44                           -- Language row
            if self._showGodModeRow then contentHraw = contentHraw + 44 end
            contentHraw = contentHraw + 44                           -- Email Backup row
            if self._showEmailForm  then contentHraw = contentHraw + 130 end
            local contentH = math.floor(contentHraw * sc)
            local offY     = math.floor((panH - contentH) / 2)

            -- Title (medium font, same weight as panel headers elsewhere)
            local hdrH = math.floor(40 * sc)
            lg.setFont(Fonts.medium)
            lg.setColor(0.875, 0.902, 0.878, 1)
            lg.printf(Locale.t("settings.title"), panX, textCY(Fonts.medium, panY + offY, hdrH), panW, 'center')
            self._settingsTitleRect = { x = panX, y = panY + offY, w = panW, h = hdrH }

            -- Divider under title
            lg.setColor(0.290, 0.212, 0.235, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + math.floor(12 * sc), panY + offY + hdrH,
                    panX + panW - math.floor(12 * sc), panY + offY + hdrH)

            -- Toggle row helper: label left, game-style button right
            local function drawToggleRow(label, enabled, rowY)
                local rowH  = math.floor(38 * sc)
                local btnW  = math.floor(64 * sc)
                local btnH  = math.floor(28 * sc)
                local btnX  = panX + panW - math.floor(16 * sc) - btnW
                local btnY  = rowY + math.floor((rowH - btnH) / 2)
                lg.setFont(Fonts.small)
                lg.setColor(0.757, 0.482, 0.361, 1)
                lg.print(label, panX + math.floor(16 * sc), textCY(Fonts.small, rowY, rowH))
                if enabled then
                    lg.setColor(0.267, 0.290, 0.396, 1)
                else
                    lg.setColor(0.133, 0.133, 0.157, 1)
                end
                roundedRect(btnX, btnY, btnW, btnH, 4, sc)
                if enabled then
                    lg.setColor(0.463, 0.529, 0.671, 1)
                else
                    lg.setColor(0.290, 0.212, 0.235, 1)
                end
                roundedRectLine(btnX, btnY, btnW, btnH, 4, sc, math.max(1, math.floor(sc)))
                lg.setFont(Fonts.small)
                if enabled then
                    lg.setColor(0.875, 0.902, 0.878, 1)
                else
                    lg.setColor(0.290, 0.212, 0.235, 1)
                end
                lg.printf(enabled and "ON" or "OFF", btnX, textCY(Fonts.small, btnY, btnH), btnW, 'center')
                return { x = btnX, y = btnY, w = btnW, h = btnH }
            end

            -- Two-option segmented row (label left, EN/ES buttons right). Used
            -- for the language picker; mirrors drawToggleRow's geometry.
            local function drawSegRow(label, options, current, rowY)
                local rowH  = math.floor(38 * sc)
                local segH  = math.floor(28 * sc)
                local gap   = math.floor(6 * sc)
                local n     = #options
                local totalW = math.floor(120 * sc)
                local segW  = math.floor((totalW - gap * (n - 1)) / n)
                local startX = panX + panW - math.floor(16 * sc) - totalW
                local segY  = rowY + math.floor((rowH - segH) / 2)
                lg.setFont(Fonts.small)
                lg.setColor(0.757, 0.482, 0.361, 1)
                lg.print(label, panX + math.floor(16 * sc), textCY(Fonts.small, rowY, rowH))
                local rects = {}
                for i, opt in ipairs(options) do
                    local sx  = startX + (i - 1) * (segW + gap)
                    local sel = (opt.value == current)
                    if sel then lg.setColor(0.267, 0.290, 0.396, 1) else lg.setColor(0.133, 0.133, 0.157, 1) end
                    roundedRect(sx, segY, segW, segH, 4, sc)
                    if sel then lg.setColor(0.463, 0.529, 0.671, 1) else lg.setColor(0.290, 0.212, 0.235, 1) end
                    roundedRectLine(sx, segY, segW, segH, 4, sc, math.max(1, math.floor(sc)))
                    lg.setColor(sel and {0.875, 0.902, 0.878, 1} or {0.463, 0.529, 0.671, 1})
                    lg.printf(opt.text, sx, textCY(Fonts.small, segY, segH), segW, 'center')
                    rects[opt.value] = { x = sx, y = segY, w = segW, h = segH }
                end
                return rects
            end

            local row1Y = panY + offY + math.floor(46 * sc)
            local row2Y = panY + offY + math.floor(90 * sc)
            local langY = panY + offY + math.floor(134 * sc)
            self._settingsMusicRect = drawToggleRow(Locale.t("settings.music"), AudioManager.musicEnabled, row1Y)
            self._settingsSFXRect   = drawToggleRow(Locale.t("settings.sfx"),   AudioManager.sfxEnabled,   row2Y)
            self._settingsLangRects = drawSegRow(Locale.t("settings.language"),
                { { value = "en", text = "EN" }, { value = "es", text = "ES" } },
                Locale.get(), langY)

            -- Hidden God Mode row (revealed by tapping SETTINGS title 3 times)
            self._settingsGodModeRect = nil
            if self._showGodModeRow then
                local row3Y = panY + offY + math.floor(178 * sc)
                self._settingsGodModeRect = drawToggleRow(Locale.t("settings.god_mode"), _G.GodMode == true, row3Y)
            end

            -- Email Backup action row (always shown)
            do
                local baseRowOffset = self._showGodModeRow and 222 or 178
                local emailRowY = panY + offY + math.floor(baseRowOffset * sc)
                local rowH  = math.floor(38 * sc)
                local btnW  = math.floor(80 * sc)
                local btnH  = math.floor(28 * sc)
                local btnX  = panX + panW - math.floor(16 * sc) - btnW
                local btnY2 = emailRowY + math.floor((rowH - btnH) / 2)
                local hasBackup = _G.PlayerData and _G.PlayerData.hasEmailBackup
                local btnLabel = hasBackup and Locale.t("settings.linked") or Locale.t("settings.set_up")

                lg.setFont(Fonts.small)
                lg.setColor(0.757, 0.482, 0.361, 1)
                lg.print(Locale.t("settings.email_backup"), panX + math.floor(16 * sc), textCY(Fonts.small, emailRowY, rowH))

                if hasBackup then
                    lg.setColor(0.349, 0.431, 0.278, 1)
                else
                    lg.setColor(0.267, 0.290, 0.396, 1)
                end
                roundedRect(btnX, btnY2, btnW, btnH, 4, sc)
                if hasBackup then
                    lg.setColor(0.608, 0.631, 0.373, 1)
                else
                    lg.setColor(0.463, 0.529, 0.671, 1)
                end
                roundedRectLine(btnX, btnY2, btnW, btnH, 4, sc, math.max(1, math.floor(sc)))
                lg.setFont(Fonts.small)
                lg.setColor(0.875, 0.902, 0.878, 1)
                lg.printf(btnLabel, btnX, textCY(Fonts.small, btnY2, btnH), btnW, 'center')
                self._settingsEmailRect = { x = btnX, y = btnY2, w = btnW, h = btnH }

                -- Inline email/password form
                if self._showEmailForm then
                    local formY = emailRowY + math.floor(44 * sc)
                    local fieldW = math.floor(panW - 32 * sc)
                    local fieldH = math.floor(32 * sc)
                    local fieldX = panX + math.floor(16 * sc)

                    -- Status message
                    if self._emailFormStatus then
                        local isOk = (self._emailFormStatus == "ok")
                        lg.setFont(Fonts.tiny)
                        lg.setColor(isOk and {0.608, 0.631, 0.373, 1} or {0.757, 0.482, 0.361, 1})
                        local msg = isOk and Locale.t("settings.saved") or self._emailFormStatus
                        lg.printf(msg, panX, formY - math.floor(14 * sc), panW, 'center')
                    elseif self._emailFormStatus == "saving" then
                        lg.setFont(Fonts.tiny)
                        lg.setColor(0.7, 0.7, 0.7, 1)
                        lg.printf(Locale.t("settings.saving"), panX, formY - math.floor(14 * sc), panW, 'center')
                    end

                    -- Email field
                    local emailActive = (self._emailActiveField == "email")
                    lg.setColor(emailActive and {0.267, 0.290, 0.396, 1} or {0.133, 0.133, 0.157, 1})
                    roundedRect(fieldX, formY, fieldW, fieldH, 4, sc)
                    lg.setColor(emailActive and {0.663, 0.733, 0.800, 1} or {0.463, 0.529, 0.671, 1})
                    roundedRectLine(fieldX, formY, fieldW, fieldH, 4, sc, math.max(1, math.floor(sc)))
                    lg.setFont(Fonts.tiny)
                    lg.setColor(#self._emailText == 0 and {0.4, 0.4, 0.45, 1} or {1, 1, 1, 1})
                    local emailDisp = #self._emailText == 0 and Locale.t("settings.email") or self._emailText
                    lg.print(emailDisp, fieldX + math.floor(6 * sc), textCY(Fonts.tiny, formY, fieldH))
                    self._emailInputRect = { x = fieldX, y = formY, w = fieldW, h = fieldH }

                    -- Password field
                    local pwY2 = formY + fieldH + math.floor(6 * sc)
                    local pwActive = (self._emailActiveField == "password")
                    lg.setColor(pwActive and {0.267, 0.290, 0.396, 1} or {0.133, 0.133, 0.157, 1})
                    roundedRect(fieldX, pwY2, fieldW, fieldH, 4, sc)
                    lg.setColor(pwActive and {0.663, 0.733, 0.800, 1} or {0.463, 0.529, 0.671, 1})
                    roundedRectLine(fieldX, pwY2, fieldW, fieldH, 4, sc, math.max(1, math.floor(sc)))
                    lg.setFont(Fonts.tiny)
                    lg.setColor(#self._passwordText == 0 and {0.4, 0.4, 0.45, 1} or {1, 1, 1, 1})
                    local pwDisp = #self._passwordText == 0 and Locale.t("settings.password_hint") or string.rep("*", #self._passwordText)
                    lg.print(pwDisp, fieldX + math.floor(6 * sc), textCY(Fonts.tiny, pwY2, fieldH))
                    self._passwordInputRect = { x = fieldX, y = pwY2, w = fieldW, h = fieldH }

                    -- Save + Cancel buttons
                    local canSave = #self._emailText > 0 and #self._passwordText >= 6
                    local saveBtnW  = math.floor(96 * sc)
                    local cancelBtnW = math.floor(76 * sc)
                    local gap       = math.floor(8 * sc)
                    local bH        = math.floor(28 * sc)
                    local totalW    = saveBtnW + gap + cancelBtnW
                    local bStartX   = panX + math.floor((panW - totalW) / 2)
                    local bY2       = pwY2 + fieldH + math.floor(8 * sc)

                    lg.setColor(canSave and {0.267, 0.290, 0.396, 1} or {0.133, 0.133, 0.157, 1})
                    roundedRect(bStartX, bY2, saveBtnW, bH, 4, sc)
                    lg.setColor(canSave and {0.463, 0.529, 0.671, 1} or {0.133, 0.133, 0.157, 1})
                    roundedRectLine(bStartX, bY2, saveBtnW, bH, 4, sc, math.max(1, math.floor(sc)))
                    lg.setFont(Fonts.small)
                    lg.setColor(canSave and {0.875, 0.902, 0.878, 1} or {0.290, 0.212, 0.235, 1})
                    lg.printf(Locale.t("settings.save"), bStartX, textCY(Fonts.small, bY2, bH), saveBtnW, 'center')
                    self._emailSaveBtnRect = canSave and { x = bStartX, y = bY2, w = saveBtnW, h = bH } or nil

                    local cBX = bStartX + saveBtnW + gap
                    lg.setColor(0.133, 0.133, 0.157, 1)
                    roundedRect(cBX, bY2, cancelBtnW, bH, 4, sc)
                    lg.setColor(0.290, 0.212, 0.235, 1)
                    roundedRectLine(cBX, bY2, cancelBtnW, bH, 4, sc, math.max(1, math.floor(sc)))
                    lg.setFont(Fonts.small)
                    lg.setColor(0.757, 0.482, 0.361, 1)
                    lg.printf(Locale.t("common.cancel"), cBX, textCY(Fonts.small, bY2, bH), cancelBtnW, 'center')
                    self._emailCancelBtnRect = { x = cBX, y = bY2, w = cancelBtnW, h = bH }
                else
                    self._emailInputRect     = nil
                    self._passwordInputRect  = nil
                    self._emailSaveBtnRect   = nil
                    self._emailCancelBtnRect = nil
                end
            end

            lg.pop()

            self._settingsPanelRect  = { x = panX, y = panY, w = panW, h = panH }
        end
    end

    -- ── input ───────────────────────────────────────────────────────────────

    local function inRect(r, x, y)
        return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
    end

    function self:handlePress(x, y)
        if self._exitAnim.active then return end
        self.isPressed  = true
        self.pressX     = x
        self.pressY     = y
        self.hasMoved   = false

        -- Settings button spring squish (always active, before overlay guard)
        if inRect(self._settingsBtnRect, x, y) then
            self._settingsSpring.pressed = true
        end

        -- Overlays absorb all presses
        if self.showSettings or self._showLeaderboard or self._showRules then return end

        -- Button spring press
        if inRect(self._playBtnRect, x, y)    then self._playSpring.pressed    = true end
        if inRect(self._sandboxBtnRect, x, y) then self._sbtnSpring.pressed    = true end
        if inRect(self._roomToggleRect, x, y) then self._roomSpring.pressed    = true end
        if inRect(self._rankBtnRect, x, y)    then self._rankSpring.pressed    = true end
        if inRect(self._rulesBtnRect, x, y)   then self._rulesBtnSpring.pressed = true end
    end

    function self:handleMove(x, y)
        if not self.isPressed then return end
        local dx = x - self.pressX
        local dy = y - self.pressY
        if not self.hasMoved and (math.abs(dx) > self.MOVE_CANCEL or math.abs(dy) > self.MOVE_CANCEL) then
            self.hasMoved = true
            -- Dragged off: cancel any pending button squish
            self._playSpring.pressed     = false
            self._sbtnSpring.pressed     = false
            self._roomSpring.pressed     = false
            self._rankSpring.pressed     = false
            self._rulesBtnSpring.pressed = false
            self._settingsSpring.pressed = false
        end
    end

    function self:handleRelease(x, y)
        self.isPressed = false
        self._playSpring.pressed     = false
        self._sbtnSpring.pressed     = false
        self._roomSpring.pressed     = false
        self._rankSpring.pressed     = false
        self._rulesBtnSpring.pressed = false
        self._settingsSpring.pressed = false

        -- ── Settings overlay ──────────────────────────────────────────────────
        if self.showSettings then
            -- Hidden title tap counter (3 taps reveals God Mode row)
            if inRect(self._settingsTitleRect, x, y) then
                local now = love.timer.getTime()
                if now - (self._settingsTitleLastTap or 0) < 1.5 then
                    self._settingsTitleTaps = (self._settingsTitleTaps or 0) + 1
                else
                    self._settingsTitleTaps = 1
                end
                self._settingsTitleLastTap = now
                if self._settingsTitleTaps >= 3 then
                    self._showGodModeRow = true
                    self._settingsTitleTaps = 0
                end
                return
            end
            -- God Mode toggle
            if inRect(self._settingsGodModeRect, x, y) then
                _G.GodMode = not _G.GodMode
                AudioManager.playTap()
                return
            end
            -- Music toggle
            if inRect(self._settingsMusicRect, x, y) then
                AudioManager.setMusic(not AudioManager.musicEnabled)
                return
            end
            -- SFX toggle
            if inRect(self._settingsSFXRect, x, y) then
                AudioManager.setSFX(not AudioManager.sfxEnabled)
                AudioManager.playTap()
                return
            end
            -- Language picker (EN / ES)
            if self._settingsLangRects then
                for lang, r in pairs(self._settingsLangRects) do
                    if inRect(r, x, y) then
                        Locale.set(lang)
                        AudioManager.playTap()
                        return
                    end
                end
            end
            -- Email form: Save button
            if self._showEmailForm and inRect(self._emailSaveBtnRect, x, y) then
                self:doLinkEmail()
                return
            end
            -- Email form: Cancel button
            if self._showEmailForm and inRect(self._emailCancelBtnRect, x, y) then
                self._showEmailForm     = false
                self._emailText        = ""
                self._passwordText     = ""
                self._emailActiveField = nil
                self._emailFormStatus  = nil
                love.keyboard.setTextInput(false)
                return
            end
            -- Email form: field focus
            if self._showEmailForm then
                if inRect(self._emailInputRect, x, y) then
                    local r = self._emailInputRect
                    self._emailActiveField = "email"
                    love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                    return
                end
                if inRect(self._passwordInputRect, x, y) then
                    local r = self._passwordInputRect
                    self._emailActiveField = "password"
                    love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                    return
                end
            end
            -- Email Backup row button
            if inRect(self._settingsEmailRect, x, y) then
                local hasBackup = _G.PlayerData and _G.PlayerData.hasEmailBackup
                if not hasBackup then
                    self._showEmailForm    = true
                    self._emailFormStatus  = nil
                    self._emailActiveField = nil
                end
                AudioManager.playTap()
                return
            end
            -- Tap outside the panel closes overlay (also collapses email form)
            if self._settingsPanelRect then
                local r = self._settingsPanelRect
                if x < r.x or x > r.x + r.w or y < r.y or y > r.y + r.h then
                    self.showSettings      = false
                    self._showEmailForm    = false
                    self._emailText        = ""
                    self._passwordText     = ""
                    self._emailActiveField = nil
                    self._emailFormStatus  = nil
                    love.keyboard.setTextInput(false)
                end
            end
            return
        end

        -- ── Leaderboard overlay ────────────────────────────────────────────────
        if self._showLeaderboard then
            if inRect(self._lbCloseRect, x, y) then
                self._showLeaderboard = false
                AudioManager.playTap()
                return
            end
            -- Tap outside the panel closes
            if self._lbPanelRect then
                local r = self._lbPanelRect
                if x < r.x or x > r.x + r.w or y < r.y or y > r.y + r.h then
                    self._showLeaderboard = false
                end
            end
            return
        end

        -- ── Rules overlay ──────────────────────────────────────────────────────
        if self._showRules then
            if inRect(self._rulesCloseRect, x, y) then
                self._showRules = false
                AudioManager.playTap()
                return
            end
            -- Reyes (4 vs 8 kings)
            if self._rulesReyesRects then
                for value, r in pairs(self._rulesReyesRects) do
                    if inRect(r, x, y) then
                        GameSettings.reyes8 = value
                        GameSettings.save()
                        AudioManager.playTap()
                        return
                    end
                end
            end
            -- Emotes (on/off)
            if self._rulesEmotesRect then
                for value, r in pairs(self._rulesEmotesRect) do
                    if inRect(r, x, y) then
                        GameSettings.emotes = value
                        GameSettings.save()
                        AudioManager.playTap()
                        return
                    end
                end
            end
            -- Sets (best of 1/3/5)
            if self._rulesBestRects then
                for value, r in pairs(self._rulesBestRects) do
                    if inRect(r, x, y) then
                        GameSettings.bestOf = value
                        GameSettings.save()
                        AudioManager.playTap()
                        return
                    end
                end
            end
            -- Tap outside the panel closes
            if self._rulesPanelRect then
                local r = self._rulesPanelRect
                if x < r.x or x > r.x + r.w or y < r.y or y > r.y + r.h then
                    self._showRules = false
                end
            end
            return
        end

        -- ── Settings "+" button ────────────────────────────────────────────────
        if inRect(self._settingsBtnRect, x, y) then
            self.showSettings = true
            return
        end

        if self.hasMoved then return end  -- dragged, not a tap

        -- ── Ranking button → open leaderboard popup ─────────────────────────────
        if inRect(self._rankBtnRect, x, y) then
            AudioManager.playTap()
            self._showLeaderboard = true
            return
        end

        -- ── Rules button → open rules popup ──────────────────────────────────────
        if inRect(self._rulesBtnRect, x, y) then
            AudioManager.playTap()
            self._showRules = true
            return
        end

        -- ── Private / Public room toggle ────────────────────────────────────────
        if inRect(self._roomToggleRect, x, y) then
            AudioManager.playTap()
            self._privateMode = not self._privateMode
            if self._privateMode then
                -- Focus the code input right away for convenience
                self._roomKeyActive = true
                self._cursorTimer   = 0
                love.keyboard.setTextInput(true)
            else
                -- Back to public matchmaking
                self._roomKeyActive = false
                self._roomKeyText   = ""
                love.keyboard.setTextInput(false)
            end
            return
        end

        -- ── Code input focus (private mode) ─────────────────────────────────────
        if self._privateMode and inRect(self._roomKeyRect, x, y) then
            local r = self._roomKeyRect
            self._roomKeyActive = true
            self._cursorTimer   = 0
            love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
            return
        end

        -- ── PLAY button ─────────────────────────────────────────────────────────
        if inRect(self._playBtnRect, x, y) then
            AudioManager.playTap()
            if self._privateMode then
                self:tryJoinPrivateRoom()
            else
                self:startPublicMatch()
            end
            return
        end

        -- ── SANDBOX button ───────────────────────────────────────────────────────
        if inRect(self._sandboxBtnRect, x, y) then
            AudioManager.playTap()
            TransitionManager.cloudCurtain(function()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('game', false, 1, false, true)
            end)
            return
        end

        -- Tap anywhere else deactivates the code input
        if self._roomKeyActive then
            self._roomKeyActive = false
            love.keyboard.setTextInput(false)
        end
    end

    function self:startPublicMatch()
        if _G.GameSocket and _G.GameSocket:isConnected() then
            self:removeSocketHandlers()
            local sock = _G.GameSocket
            self:startExitAnim(function()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('lobby', sock)
            end)
        elseif _G.GameSocket then
            -- Socket exists but dead — reconnect first
            self:startReconnect()
        else
            -- Not logged in, go through loading which will auto-auth via device
            self:startExitAnim(function()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('loading')
            end)
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 then self:handlePress(x, y) end
    end
    function self:mousemoved(x, y)
        self:handleMove(x, y)
    end
    function self:mousereleased(x, y, button)
        if button == 1 then self:handleRelease(x, y) end
    end

    function self:keypressed(key)
        -- Email form input handling
        if self.showSettings and self._showEmailForm then
            if key == "backspace" then
                if self._emailActiveField == "email" then
                    self._emailText = self._emailText:sub(1, -2)
                elseif self._emailActiveField == "password" then
                    self._passwordText = self._passwordText:sub(1, -2)
                end
            elseif key == "tab" then
                self._emailActiveField = (self._emailActiveField == "email") and "password" or "email"
            elseif key == "return" or key == "kpenter" then
                if self._emailActiveField == "email" then
                    self._emailActiveField = "password"
                else
                    self:doLinkEmail()
                end
            elseif key == "escape" then
                self._showEmailForm     = false
                self._emailActiveField  = nil
                love.keyboard.setTextInput(false)
            end
            return
        end
        -- Room key input handling
        if self._roomKeyActive then
            if key == "backspace" then
                self._roomKeyText = self._roomKeyText:sub(1, -2)
            elseif key == "return" or key == "kpenter" then
                self:tryJoinPrivateRoom()
            elseif key == "escape" then
                self._roomKeyActive = false
                love.keyboard.setTextInput(false)
            end
            return
        end

        if key == "escape" then
            if self._showLeaderboard then
                self._showLeaderboard = false
            elseif self._showRules then
                self._showRules = false
            elseif self.showSettings then
                self.showSettings = false
            end
            return
        end
    end

    function self:textinput(t)
        if self.showSettings and self._showEmailForm then
            if self._emailActiveField == "email" then
                if #self._emailText < 128 and t:match("^[%g]$") then
                    self._emailText = self._emailText .. t
                end
            elseif self._emailActiveField == "password" then
                if #self._passwordText < 128 and t:match("^[%g]$") then
                    self._passwordText = self._passwordText .. t
                end
            end
            return
        end
        if self._roomKeyActive then
            if t:match("^[%w]+$") and #self._roomKeyText < 12 then
                self._roomKeyText = self._roomKeyText .. t:upper()
            end
        end
    end

    function self:doLinkEmail()
        local email = self._emailText:match("^%s*(.-)%s*$"):lower()
        local pw    = self._passwordText
        if not email:match("^[^@]+@[^@]+%.[^@]+$") then
            self._emailFormStatus      = Locale.t("settings.err_invalid_email")
            self._emailFormStatusTimer = 2.5
            return
        end
        if #pw < 6 then
            self._emailFormStatus      = Locale.t("settings.err_short_pw")
            self._emailFormStatusTimer = 2.5
            return
        end
        if not (_G.GameSocket and _G.GameSocket:isConnected()) then
            self._emailFormStatus      = Locale.t("settings.err_not_connected")
            self._emailFormStatusTimer = 2.5
            return
        end
        self._emailFormStatus = "saving"
        _G.GameSocket:send("link_email", { email = email, password = pw })
    end

    function self:tryJoinPrivateRoom()
        local key = self._roomKeyText:match("^%s*(.-)%s*$")
        if #key < 1 then
            self._notice      = Locale.t("menu.err_enter_code")
            self._noticeTimer = 2.0
            return
        end
        if not (_G.GameSocket and _G.GameSocket:isConnected()) then
            self._notice      = Locale.t("settings.err_not_connected")
            self._noticeTimer = 2.0
            return
        end
        self._roomKeyActive = false
        love.keyboard.setTextInput(false)
        self:removeSocketHandlers()
        local sock = _G.GameSocket
        self:startExitAnim(function()
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('lobby', sock, key)
        end)
    end

    function self:startExitAnim(callback)
        self._exitAnim.active    = true
        self._exitAnim.progress  = 0
        self._exitAnim.direction = 1
        self._exitAnim.callback  = callback
    end

    return self
end

return MenuScreen
