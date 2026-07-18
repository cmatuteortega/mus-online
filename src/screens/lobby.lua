-- Mus Online – Matchmaking Lobby Screen
-- Auto-joins queue, waits for match, then launches GameScreen.

local Screen      = require('lib.screen')
local Constants   = require('src.constants')
local DeckManager = require('src.deck_manager')
local UnitRegistry = require('src.unit_registry')
local PaletteShader = require('src.palette_shader')

local LobbyScreen = {}

function LobbyScreen.new()
    local self = Screen.new()

    -- ── helpers ──────────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    local function textCY(font, y, h)
        return y + (h - font:getHeight()) / 2
    end

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init(client, roomKey)
        self.client = client  -- Authenticated socket from login/menu
        self.roomKey = roomKey or nil  -- nil = public queue, string = private match key
        self.status = "queueing"  -- queueing | matched | error
        self.statusMsg = "Finding match..."
        self.queueStartTime = love.timer.getTime()
        self.mySeat = nil
        self.myTeam = nil
        self.tablePlayers = nil
        self.tableRanked = false
        self.privateCount = nil
        self.privatePlayers = nil
        self.privateIsHost = false
        self.myTrophies = _G.PlayerData and _G.PlayerData.trophies or 0

        -- Cancel button hit rect
        self._cancelBtnRect = nil
        self._cancelPressedInside = false

        -- Random waiting sentence (picked once at init)
        local sentences = {
            "Finding a worthy opponent...",
            "Waiting for the ideal match...",
            "Looking for a duel...",
            "Sharpening swords before the battle...",
            "Scouts are searching the realm...",
            "Summoning a rival commander...",
            "The arena awaits a challenger...",
            "Seeking someone brave enough to face you...",
        }
        self.waitingSentence = sentences[math.random(#sentences)]

        -- Background sprite
        self.bgSprite  = love.graphics.newImage('src/assets/background_menu.png')
        self.bgOffsetY = -49  -- tweak to shift background up (negative) or down (positive)

        -- Match delay timer
        self.matchTimer = nil

        -- Deck preview (mirrors menu play-panel)
        self.unitOrder          = UnitRegistry.getAllUnitTypes()
        table.sort(self.unitOrder)
        self.sprites            = {}
        self.spriteTrimBottoms  = {}
        self.dirSprites         = {}
        self.idleAnim           = {}
        self.attackAnim         = {}
        self.previewLayout      = {}
        for _, utype in ipairs(self.unitOrder) do
            local loaded = UnitRegistry.loadDirectionalSprites(utype)
            self.sprites[utype]           = loaded.front
            self.spriteTrimBottoms[utype] = loaded.frontTrimBottom
            self.dirSprites[utype]        = loaded
            self.idleAnim[utype]          = { frameIndex = 1, timer = 0 }
            self.attackAnim[utype]        = { active = false, progress = 0, duration = 0.45 }
        end
        self:buildPreviewLayout()

        -- Cancel button spring physics
        self._cancelSpring = { scale = 1.0, vel = 0.0, pressed = false }

        -- Ticker stripe
        self._tickerOffset = 0
        self._tickerMsg    = "matchmaking  -  matchmaking  -  matchmaking  -  matchmaking  -  "
        self._tickerMsgPx  = 0  -- computed lazily once font is available

        -- Register network callbacks
        self:registerNetworkCallbacks()

        -- Auto-join queue (private or public)
        self:joinQueue()

        if self.roomKey then
            print("LobbyScreen: Joining private queue with key=" .. self.roomKey)
        else
            print("LobbyScreen: Auto-joining matchmaking queue")
        end
    end

    function self:buildPreviewLayout()
        self.previewLayout = {}
        local deck = DeckManager.getActiveDeck()
        if not deck then return end

        -- Collect unit types with at least 1 card, in stable sorted order
        local units = {}
        for utype, count in pairs(deck.counts) do
            if count > 0 then table.insert(units, utype) end
        end
        table.sort(units)
        if #units == 0 then return end

        local occupied = {}
        local placed   = 0
        local function occupy(r, c)
            placed = placed + 1
            occupied[r * 10 + c] = true
            table.insert(self.previewLayout, { unitType = units[placed], col = c, row = r })
        end

        -- Phase 1: V formation — tip at front-center, arms extending back-outward
        --   Row 4 (front): col 3  — tip
        --   Row 3:         col 2, col 4
        --   Row 2:         col 1, col 5
        --   Row 1 (back):  col 1, col 5
        local vPos = {
            {4,3}, {3,2},{3,4}, {2,1},{2,5}, {1,1},{1,5},
        }
        for _, p in ipairs(vPos) do
            if placed >= #units then break end
            occupy(p[1], p[2])
        end

        -- Phase 2: spaced positions — no occupied cardinal neighbour (1-cell gap)
        if placed < #units then
            local function cardinalHit(r, c)
                return occupied[(r-1)*10+c] or occupied[(r+1)*10+c]
                    or occupied[r*10+(c-1)] or occupied[r*10+(c+1)]
            end
            for r = 1, 4 do
                for c = 1, 5 do
                    if placed >= #units then break end
                    if not occupied[r*10+c] and not cardinalHit(r, c) then
                        occupy(r, c)
                    end
                end
            end
        end

        -- Phase 3: no more spaced room — fill remaining cells randomly
        if placed < #units then
            local rem = {}
            for r = 1, 4 do
                for c = 1, 5 do
                    if not occupied[r*10+c] then table.insert(rem, {r,c}) end
                end
            end
            for i = #rem, 2, -1 do
                local j = math.random(i)
                rem[i], rem[j] = rem[j], rem[i]
            end
            for _, p in ipairs(rem) do
                if placed >= #units then break end
                occupy(p[1], p[2])
            end
        end
    end

    function self:getPreviewFrame(utype)
        local d = self.dirSprites[utype]
        if d and d.hasDirectionalSprites then
            local atk = self.attackAnim[utype]
            if atk.active and d.directional.hit and d.directional.hit[0] then
                local dirData = d.directional.hit[0]
                local count   = #dirData.frames
                local p       = atk.progress
                local idx
                if count >= 3 then
                    if     p < 1/3 then idx = 1
                    elseif p < 2/3 then idx = 2
                    else                idx = 3 end
                else
                    idx = math.min(count, math.floor(p * count) + 1)
                end
                return dirData.frames[idx], dirData.trimBottom[idx]
            end
            local aio = d.directional.actionIdleOverride
            if aio and (aio[0] or aio[180]) then
                local ad  = aio[0] or aio[180]
                local idx = math.min(self.idleAnim[utype].frameIndex, #ad.frames)
                return ad.frames[idx], ad.trimBottom[idx] or 0
            end
            if d.directional.idle and d.directional.idle[0] then
                local dirData = d.directional.idle[0]
                local idx     = self.idleAnim[utype].frameIndex
                return dirData.frames[idx], dirData.trimBottom[idx]
            end
        end
        return self.sprites[utype], self.spriteTrimBottoms[utype] or 0
    end

    function self:registerNetworkCallbacks()
        self._cb_queueJoined = self.client:on("queue_joined", function()
            self.status = "queueing"
            self.statusMsg = "Finding match..."
            print("Queue joined")
        end)

        self._cb_privateQueueJoined = self.client:on("private_queue_joined", function()
            self.status = "queueing"
            self.statusMsg = "Waiting for friend..."
            print("Private queue joined")
        end)

        self._cb_queueLeft = self.client:on("queue_left", function()
            print("Queue left")
        end)

        self._cb_matchFound = self.client:on("match_found", function(data)
            -- 4-player table: seat 1-4, team 1 = seats 1,3 / team 2 = seats 2,4
            self.mySeat      = data.seat
            self.myTeam      = data.team
            self.tablePlayers = data.players or {}
            self.tableRanked  = data.ranked or false
            self.myTrophies  = data.my_trophies or self.myTrophies
            self.status = "matched"
            self.statusMsg = "Match found!"
            print("Match found: seat " .. tostring(data.seat) .. " of 4")

            -- Show match info briefly before launching
            self.matchTimer = 1.6
        end)

        self._cb_privateLobby = self.client:on("private_lobby_update", function(data)
            self.status = "queueing"
            self.privateCount   = data.count or 1
            self.privatePlayers = data.players or {}
            self.privateIsHost  = data.is_host or false
        end)

        self._cb_oppDisconn = self.client:on("opponent_disconnected", function()
            self.status = "error"
            self.statusMsg = "Opponent disconnected"
        end)

        self._cb_error = self.client:on("error", function(data)
            if data.reason == "Not authenticated" and _G.PlayerData and _G.PlayerData.token then
                -- Session dropped — silently reconnect using stored token
                self.status = "reconnecting"
                self.statusMsg = "Reconnecting..."
                self.client:send("reconnect_with_token", {token = _G.PlayerData.token, device_id = _G.DeviceId or ""})
            else
                self.status = "error"
                self.statusMsg = data.reason or "Error occurred"
            end
        end)

        self._cb_loginSuccess = self.client:on("login_success", function(data)
            if self.status == "reconnecting" then
                -- Session restored — update trophies and re-join queue
                _G.PlayerData.trophies = data.trophies
                self.myTrophies = data.trophies
                self.status = "queueing"
                self:joinQueue()
            end
        end)
    end

    function self:joinQueue()
        if not self.client then
            self.status = "error"
            self.statusMsg = "No connection"
            return
        end

        if self.roomKey then
            self.client:send("private_queue_join", {
                player_id = _G.PlayerData.id,
                room_key  = self.roomKey
            })
        else
            self.client:send("queue_join", {
                player_id = _G.PlayerData.id,
                trophies  = _G.PlayerData.trophies
            })
        end
    end

    function self:leaveQueue()
        if self.client then
            local msg = self.roomKey and "private_queue_leave" or "queue_leave"
            self.client:send(msg, {})
        end
    end

    -- ── Update ───────────────────────────────────────────────────────────────

    function self:update(dt)
        -- Poll network
        if self.client then
            local ok, err = pcall(function() self.client:update() end)
            if not ok then
                print("[LOBBY] Socket error: " .. tostring(err))
                pcall(function() self.client:disconnect() end)
                self.client = nil
                _G.GameSocket = nil
                self.status    = "error"
                self.statusMsg = "Sin conexión a internet"
            end
        end

        -- Transition to game after match found
        if self.matchTimer then
            self.matchTimer = self.matchTimer - dt
            if self.matchTimer <= 0 then
                self.matchTimer = nil

                -- Update player trophies globally (server sent latest)
                _G.PlayerData.trophies = self.myTrophies

                -- Store table info globally for the game screen
                _G.TableInfo = {
                    seat    = self.mySeat,
                    team    = self.myTeam,
                    players = self.tablePlayers,
                    ranked  = self.tableRanked,
                }

                local seat   = self.mySeat
                local client = self.client
                TransitionManager.cloudCurtain(function()
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('game', true, seat, client)
                end)
            end
        end

        -- Advance idle and attack animations for deck preview
        local DEFAULT_IDLE_FRAME_DUR = 0.12 * 2
        local IDLE_FRAME_DUR_OVERRIDE = { marrow = 0.18 }
        for _, utype in ipairs(self.unitOrder) do
            local d = self.dirSprites[utype]
            if d and d.hasDirectionalSprites and d.directional.idle and d.directional.idle[0] then
                local frames   = d.directional.idle[0].frames
                local anim     = self.idleAnim[utype]
                local frameDur = IDLE_FRAME_DUR_OVERRIDE[utype] or DEFAULT_IDLE_FRAME_DUR
                anim.timer = anim.timer + dt
                if anim.timer >= frameDur then
                    anim.timer      = anim.timer - frameDur
                    anim.frameIndex = (anim.frameIndex % #frames) + 1
                end
            end
            local atk = self.attackAnim[utype]
            if atk.active then
                atk.progress = atk.progress + dt / atk.duration
                if atk.progress >= 1 then atk.active = false; atk.progress = 0 end
            end
        end

        -- Spring physics for cancel button (k=480, d=18 — matches menu style)
        local function updateSpring(sp, dt2)
            local target = sp.pressed and 0.93 or 1.0
            local accel  = -480 * (sp.scale - target) - 18 * sp.vel
            sp.vel   = sp.vel   + accel * dt2
            sp.scale = sp.scale + sp.vel  * dt2
            sp.scale = math.max(0.85, math.min(1.12, sp.scale))
        end
        updateSpring(self._cancelSpring, dt)

        -- Ticker stripe: swap message on status change, scroll continuously
        local tickerMsg = (self.status == "matched")
            and "match found!  -  match found!  -  match found!  -  match found!  -  "
            or  "matchmaking  -  matchmaking  -  matchmaking  -  matchmaking  -  "
        if tickerMsg ~= self._tickerMsg then
            self._tickerMsg    = tickerMsg
            self._tickerMsgPx  = 0
            self._tickerOffset = 0
        end
        if self._tickerMsgPx == 0 and Fonts and Fonts.small then
            self._tickerMsgPx = Fonts.small:getWidth(self._tickerMsg)
        end
        local tickerSpeed = 60 * Constants.SCALE
        self._tickerOffset = self._tickerOffset + tickerSpeed * dt
        -- Loop at exactly one message width so two copies tile seamlessly
        if self._tickerMsgPx > 0 and self._tickerOffset >= self._tickerMsgPx then
            self._tickerOffset = self._tickerOffset - self._tickerMsgPx
        end
    end

    function self:drawTickerStripe(W, sc)
        local lg      = love.graphics
        local stripeY = math.floor(75 * sc + Constants.MENU_CONTENT_PUSH)
        local stripeH = math.floor(36 * sc)

        lg.setColor(0.031, 0.078, 0.118, 1)
        lg.rectangle('fill', 0, stripeY, W, stripeH)

        lg.setColor(0.125, 0.224, 0.310, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(0, stripeY, W, stripeY)
        lg.line(0, stripeY + stripeH, W, stripeY + stripeH)

        if self._tickerMsg and self._tickerMsgPx > 0 then
            lg.setScissor(0, stripeY, W, stripeH)
            lg.setFont(Fonts.small)
            if self.status == "matched" then
                lg.setColor(0.9, 0.85, 0.3, 1)
            else
                lg.setColor(0.965, 0.839, 0.741, 1)
            end
            local textY = math.floor(stripeY + (stripeH - (Fonts.small:getAscent() - Fonts.small:getDescent())) / 2)
            local x0 = math.floor(-self._tickerOffset)
            -- Draw two copies staggered by one message width for seamless tiling
            lg.print(self._tickerMsg, x0, textY)
            lg.print(self._tickerMsg, x0 + self._tickerMsgPx, textY)
            lg.setScissor()
        end
    end

    -- ── Draw ─────────────────────────────────────────────────────────────────

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE
        local cx = W / 2

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Background sprite (same pixel scale as deck preview unit sprites: 1px = CELL_SIZE/16)
        -- Compute gridY identically to the deck preview so the background aligns with it
        local bgBarH       = 90 * sc
        local bgBtnY       = (H - bgBarH) * 0.62
        local bgContentTop = 100 * sc + Constants.MENU_CONTENT_PUSH
        local bgGridH      = 4 * Constants.CELL_SIZE
        local bgGridY      = math.floor(bgContentTop + (bgBtnY - bgContentTop - bgGridH) / 2)
        if self.bgSprite then
            local imgW      = self.bgSprite:getWidth()
            local drawScale = Constants.CELL_SIZE / 16
            local drawW     = imgW * drawScale
            lg.setColor(1, 1, 1, 1)
            lg.setShader(PaletteShader.get())
            lg.draw(self.bgSprite, math.floor((W - drawW) / 2), math.floor(bgGridY + self.bgOffsetY), 0, drawScale, drawScale)
            lg.setShader()
        end

        -- Queue timer
        if self.status == "queueing" then
            local elapsed = love.timer.getTime() - self.queueStartTime
            lg.setFont(Fonts.small)
            lg.setColor(0.4, 0.4, 0.4, 0.7)
            lg.printf(string.format("%ds", math.floor(elapsed)), 0, math.floor(30 * sc + Constants.SAFE_INSET_TOP), W, 'center')
        end

        -- Ticker stripe (scrolling status text)
        self:drawTickerStripe(W, sc)

        -- ── Deck preview grid ────────────────────────────────────────────────
        local cellSize   = Constants.CELL_SIZE
        local gridW      = 5 * cellSize
        local gridH      = 4 * cellSize
        local gridX      = math.floor((W - gridW) / 2)
        local barH       = 90 * sc
        local btnY       = (H - barH) * 0.62
        local contentTop = 100 * sc + Constants.MENU_CONTENT_PUSH
        local gridY      = math.floor(contentTop + (btnY - contentTop - gridH) / 2)

        local CDARK  = Constants.COLORS.CHESS_DARK
        local CLIGHT = Constants.COLORS.CHESS_LIGHT
        for row = 1, 4 do
            for col = 1, 5 do
                local cx2 = gridX + (col - 1) * cellSize
                local cy2 = gridY + (row - 1) * cellSize
                lg.setColor((row + col) % 2 == 0 and CDARK or CLIGHT)
                lg.rectangle('fill', cx2, cy2, cellSize, cellSize)
            end
        end

        -- Grid border
        lg.setColor(0.125, 0.224, 0.310, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.rectangle('line', gridX, gridY, gridW, gridH)

        -- Animated unit sprites (draw back rows first so front rows overlap)
        local sprSc = cellSize / 16
        local sortedLayout = {}
        for i, e in ipairs(self.previewLayout) do sortedLayout[i] = e end
        table.sort(sortedLayout, function(a, b) return a.row < b.row end)
        for _, entry in ipairs(sortedLayout) do
            local img, trimBottom = self:getPreviewFrame(entry.unitType)
            if img then
                local iw, ih = img:getDimensions()
                local cx2 = gridX + (entry.col - 1) * cellSize
                local cy2 = gridY + (entry.row - 1) * cellSize
                -- Background animation (e.g. fire effects)
                local bgFrames = self.dirSprites[entry.unitType] and self.dirSprites[entry.unitType].bgAnimFrames
                if bgFrames then
                    local fps      = 8
                    local frameIdx = math.floor(love.timer.getTime() * fps) % #bgFrames + 1
                    local bgImg    = bgFrames[frameIdx]
                    local bw, bh   = bgImg:getDimensions()
                    local BOTTOM_MARGIN = 3
                    local bgOffX = math.floor(cx2 + (cellSize - bw * sprSc) / 2)
                    local bgOffY = math.floor(cy2 + cellSize - (bh - trimBottom + BOTTOM_MARGIN) * sprSc)
                    lg.setColor(1, 1, 1, 1)
                    lg.setShader(PaletteShader.get())
                    lg.draw(bgImg, bgOffX, bgOffY, 0, sprSc, sprSc)
                    lg.setShader()
                end
                local BOTTOM_MARGIN = 3
                local sx = math.floor(cx2 + (cellSize - iw * sprSc) / 2)
                local sy = math.floor(cy2 + cellSize - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.setShader(PaletteShader.get())
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
                lg.setShader()
            end
        end

        if #self.previewLayout == 0 then
            lg.setFont(Fonts.small)
            lg.setColor(0.306, 0.286, 0.373, 1)
            lg.printf("Equip a deck to preview", gridX,
                gridY + gridH / 2 - Fonts.small:getHeight() / 2, gridW, 'center')
        end

        -- ── Status area (below grid) ─────────────────────────────────────────
        local infoY = gridY + gridH + 28 * sc

        if self.status == "queueing" then
            lg.setFont(Fonts.small)
            lg.setColor(0.6, 0.6, 0.7, 1)
            lg.printf(self.waitingSentence, 0, infoY, W, 'center')

            if self.roomKey then
                lg.setFont(Fonts.tiny)
                lg.setColor(0.4, 0.4, 0.4, 0.5)
                local roomLine = "Room: " .. self.roomKey
                if self.privateCount then
                    roomLine = roomLine .. "   ·   " .. self.privateCount .. "/4 players"
                end
                lg.printf(roomLine, 0, infoY + Fonts.small:getHeight() + 8 * sc, W, 'center')
                if self.privatePlayers and #self.privatePlayers > 0 then
                    local names = {}
                    for _, p in ipairs(self.privatePlayers) do names[#names + 1] = p.username end
                    lg.printf(table.concat(names, "  ·  "), 0,
                        infoY + Fonts.small:getHeight() + 8 * sc + Fonts.tiny:getHeight() + 6 * sc, W, 'center')
                end
            end

        elseif self.status == "matched" then
            lg.setFont(Fonts.small)
            lg.setColor(0.6, 0.6, 0.7, 1)
            lg.printf("Match Found!", 0, infoY, W, 'center')

            -- Show the two teams: you+partner vs the other pair.
            local mates, rivals = {}, {}
            for _, p in ipairs(self.tablePlayers or {}) do
                local label = p.username .. (p.seat == self.mySeat and " (you)" or "")
                if p.team == self.myTeam then mates[#mates + 1] = label
                else rivals[#rivals + 1] = label end
            end
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            local y1 = infoY + Fonts.small:getHeight() + 10 * sc
            lg.printf(table.concat(mates, " + "), 0, y1, W, 'center')
            lg.setFont(Fonts.small)
            lg.setColor(0.9, 0.85, 0.3, 1)
            lg.printf("vs", 0, y1 + Fonts.medium:getHeight() + 6 * sc, W, 'center')
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf(table.concat(rivals, " + "), 0,
                y1 + Fonts.medium:getHeight() + 6 * sc + Fonts.small:getHeight() + 6 * sc, W, 'center')

        elseif self.status == "error" then
            lg.setFont(Fonts.medium)
            lg.setColor(1, 0.4, 0.4, 1)
            lg.printf(self.statusMsg, 0, infoY, W, 'center')
        end

        -- ── Cancel button (matches JOIN button in ranking panel) ────────────
        if self.status == "queueing" or self.status == "error" then
            local btnW     = math.floor(200 * sc)
            local sbtnH    = math.floor(72  * sc)
            local maxFloat = math.floor(6   * sc)
            local shadowH  = math.floor(6   * sc)
            -- Centre between bottom of deck grid and bottom of screen
            local deckBottom = gridY + gridH
            local sbtnY    = math.floor(deckBottom + (H - deckBottom - sbtnH) / 2)
            local btnX     = math.floor(cx - btnW / 2)

            local t        = love.timer.getTime()
            local idleBob  = math.sin(t * 1.8) * 2 * sc
            local idleRot  = math.sin(t * 1.3) * 0.012
            local ss       = self._cancelSpring.scale
            local sfloat   = math.floor(maxFloat * math.max(0, (ss - 0.93) / 0.07))
            local sdrawY   = sbtnY - sfloat + math.floor(idleBob)

            -- Shadow
            lg.setColor(0.031, 0.078, 0.118, 1)
            roundedRect(btnX + math.floor(2 * sc), sbtnY + shadowH, btnW, sbtnH, 8, sc)

            -- Face: pivot at center, rotate then scale (matches JOIN exactly)
            local pivX = btnX + btnW / 2
            local pivY = sdrawY + sbtnH / 2
            local bx   = -btnW / 2
            local by   = -sbtnH / 2
            lg.push()
            lg.translate(pivX, pivY)
            lg.rotate(idleRot)
            lg.scale(ss, ss)
            lg.setColor(0.600, 0.459, 0.467, 1)
            roundedRect(bx, by, btnW, sbtnH, 8, sc)
            lg.setColor(0.700, 0.559, 0.567, 1)
            roundedRectLine(bx, by, btnW, sbtnH, 8, sc, 2 * sc)
            lg.setFont(Fonts.large)
            lg.setColor(1, 1, 1, 1)
            lg.printf("Cancel", bx, textCY(Fonts.large, by, sbtnH), btnW, 'center')
            lg.pop()

            self._cancelBtnRect = { x = btnX, y = sbtnY - maxFloat, w = btnW, h = sbtnH + maxFloat }

            -- Private-room host: a second button to start now, filling with bots
            if self.roomKey and self.privateIsHost and self.status == "queueing" then
                local bbW = math.floor(230 * sc)
                local bbH = math.floor(52 * sc)
                local bbX = math.floor(cx - bbW / 2)
                local bbY = sbtnY - bbH - math.floor(16 * sc)
                lg.setColor(0.031, 0.078, 0.118, 1)
                roundedRect(bbX + math.floor(2 * sc), bbY + math.floor(4 * sc), bbW, bbH, 8, sc)
                lg.setColor(0.125, 0.324, 0.310, 1)
                roundedRect(bbX, bbY, bbW, bbH, 8, sc)
                lg.setColor(0.225, 0.424, 0.410, 1)
                roundedRectLine(bbX, bbY, bbW, bbH, 8, sc, 2 * sc)
                lg.setFont(Fonts.small)
                lg.setColor(1, 1, 1, 1)
                lg.printf("Start with bots", bbX, textCY(Fonts.small, bbY, bbH), bbW, 'center')
                self._botsBtnRect = { x = bbX, y = bbY, w = bbW, h = bbH }
            else
                self._botsBtnRect = nil
            end
        else
            self._cancelBtnRect = nil
            self._botsBtnRect = nil
        end

        -- ── Bottom info strip ────────────────────────────────────────────────
        lg.setFont(Fonts.tiny)
        lg.setColor(0.4, 0.4, 0.4, 0.5)
        if self.status == "queueing" then
            local elapsed2   = love.timer.getTime() - self.queueStartTime
            local qt         = math.floor(elapsed2)
            local baseRange  = 100
            local expandStep = 50
            local maxRange   = 500
            local expand     = math.min(math.floor(qt / 5) * expandStep, maxRange - baseRange)
            local range      = baseRange + expand
            local lo         = math.max(0, self.myTrophies - range)
            local hi         = self.myTrophies + range
            lg.printf(string.format("%d trophies  ·  searching %d – %d", self.myTrophies, lo, hi),
                0, H - math.max(50 * sc, Constants.SAFE_INSET_BOTTOM + 24 * sc), W, 'center')
        elseif self.status == "matched" then
            lg.printf("Starting game...", 0, H - math.max(50 * sc, Constants.SAFE_INSET_BOTTOM + 24 * sc), W, 'center')
        end
        if _G.PlayerData then
            lg.printf("ID: " .. _G.PlayerData.id, 0, H - math.max(30 * sc, Constants.SAFE_INSET_BOTTOM + 4 * sc), W, 'center')
        end
    end

    -- ── Input ─────────────────────────────────────────────────────────────────

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end
        if self._cancelBtnRect then
            local r = self._cancelBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self._cancelPressedInside = true
                self._cancelSpring.pressed = true
            end
        end
    end

    function self:mousereleased(x, y, button)
        if button ~= 1 then return end
        self._cancelSpring.pressed = false
        if self._botsBtnRect and self.client then
            local r = self._botsBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.client:send("private_start_bots", {})
                self._botsBtnRect = nil
                return
            end
        end
        if self._cancelPressedInside and self._cancelBtnRect then
            local r = self._cancelBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self._cancelPressedInside = false
                self:leaveQueue()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('menu', true)
                return
            end
        end
        self._cancelPressedInside = false
    end

    function self:touchpressed(_, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:touchreleased(_, x, y)
        self:mousereleased(x, y, 1)
    end

    function self:keypressed(key)
        if key == "escape" then
            self:leaveQueue()
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end
    end

    function self:close()
        -- Unregister all socket callbacks so they don't accumulate across sessions
        if self.client then
            local cbs = {self._cb_queueJoined, self._cb_queueLeft, self._cb_matchFound,
                         self._cb_oppDisconn, self._cb_error, self._cb_loginSuccess,
                         self._cb_privateQueueJoined}
            for _, cb in ipairs(cbs) do
                if cb then self.client:removeCallback(cb) end
            end
        end

        -- Leave queue if still queueing
        if self.status == "queueing" then
            self:leaveQueue()
        end

        -- Don't disconnect socket if matched (handed to GameScreen)
        if self.status == "matched" then
            print("LobbyScreen: Passing socket to GameScreen")
        end
    end

    return self
end

return LobbyScreen
