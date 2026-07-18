-- Mus Online – Game table screen.
-- Renderer + intent sender: all rules live in the server's engine; this screen
-- draws the table from server events and sends validated intents back.
--
-- Layout (540×960 portrait): own hand bottom, partner top, rivals left/right,
-- phase banner + bet state center, team scores top, action buttons above hand.

local Screen        = require('lib.screen')
local Constants     = require('src.constants')
local CardRenderer  = require('src.card_renderer')
local AudioManager  = require('src.audio_manager')

local GameScreen = {}

local STAGE_LABEL = {
    mus = "MUS", discard = "DESCARTE", grande = "GRANDE", chica = "CHICA",
    pares = "PARES", juego = "JUEGO", punto = "PUNTO", showdown = "",
}

local ACTION_LABEL = {
    mus = "Mus", no_mus = "No hay mus", paso = "Paso", envido = "Envido",
    ordago = "¡ÓRDAGO!", quiero = "Quiero", no_quiero = "No quiero",
    discard = "Descartar",
}

function GameScreen.new()
    local self = Screen.new()

    -- Handlers for game_event messages, keyed by event name (filled in below).
    local HANDLERS = {}

    -- ── init ──────────────────────────────────────────────────────────────────
    -- Signature matches the old AutoChest screen so existing menu/lobby calls
    -- work unchanged: sandbox (menu SANDBOX button) runs the engine locally
    -- with 3 bots via src/local_table.lua — no server needed.
    function self:init(isOnline, mySeat, socket, isSandbox, isTutorial)
        CardRenderer.load()
        self.isSandbox = isSandbox or false
        self.socket   = (not self.isSandbox) and socket or nil
        self.mySeat   = self.isSandbox and 1
                        or (mySeat or (_G.TableInfo and _G.TableInfo.seat) or 1)
        self.myTeam   = (self.mySeat % 2 == 1) and 1 or 2
        self.players  = {}
        if self.isSandbox then
            local LocalTable = require('src.local_table')
            for _, p in ipairs(LocalTable.roster()) do self.players[p.seat] = p end
        elseif _G.TableInfo and _G.TableInfo.players then
            for _, p in ipairs(_G.TableInfo.players) do self.players[p.seat] = p end
        end
        self.ranked   = (not self.isSandbox) and (_G.TableInfo and _G.TableInfo.ranked) or false

        self.myCards    = {}
        self.selected   = {}       -- [index] = true, for discards
        self.stage      = "waiting"
        self.turn       = nil      -- last turn info from the server
        self.turnAt     = love.timer.getTime()
        self.scores     = { 0, 0 }
        self.manoSeat   = 1
        self.handNo     = 0
        self.proposed   = 0
        self.isOrdago   = false
        self.revealed   = nil      -- [seat] = cards at showdown
        self.feed       = {}       -- rolling log of table talk lines
        self.awards     = nil      -- hand_end summary
        self.gameOver   = nil      -- { winner_team, ordago }
        self.rewards    = nil
        self.leaveArmed = false
        self.buttons    = {}
        self._pressedBtn = nil

        if self.socket then self:registerCallbacks() end

        if self.isSandbox then
            local LocalTable = require('src.local_table')
            self.localTable = LocalTable.new(function(name, data)
                local h = HANDLERS[name]
                if h then h(self, data or {}) end
            end)
            self.localTable:start()
        end
    end

    -- ── networking ────────────────────────────────────────────────────────────

    function self:say(line)
        table.insert(self.feed, { text = line, at = love.timer.getTime() })
        if #self.feed > 4 then table.remove(self.feed, 1) end
    end

    function self:nameOf(seat)
        if seat == self.mySeat then return "Tú" end
        local p = self.players[seat]
        return p and p.username or ("Seat " .. tostring(seat))
    end

    function self:registerCallbacks()
        self._cb_gameEvent = self.socket:on("game_event", function(msg)
            if not msg or not msg.name then return end
            local h = HANDLERS[msg.name]
            if h then h(self, msg.data or {}) end
        end)
        self._cb_currency = self.socket:on("currency_update", function(data)
            if _G.PlayerData then
                _G.PlayerData.gold  = data.gold or _G.PlayerData.gold
                _G.PlayerData.gems  = data.gems or _G.PlayerData.gems
                _G.PlayerData.xp    = data.xp or _G.PlayerData.xp
                _G.PlayerData.level = data.level or _G.PlayerData.level
            end
        end)
    end

    HANDLERS.hand_start = function(s, d)
        s.handNo = d.hand_no or (s.handNo + 1)
        s.manoSeat = d.mano_seat or s.manoSeat
        s.scores = d.scores or s.scores
        s.stage = "mus"
        s.revealed = nil
        s.awards = nil
        s.selected = {}
        s:say("Mano " .. s.handNo .. " — es mano " .. s:nameOf(s.manoSeat))
    end

    HANDLERS.your_cards = function(s, d)
        s.myCards = d.cards or {}
        s.selected = {}
        -- Deal-in animation (AutoChest style): cards slide in from off-screen
        -- right with a staggered delay and an exponential smoother.
        s.cardAnims = {}
        local W = Constants.GAME_WIDTH
        for i = 1, #s.myCards do
            s.cardAnims[i] = {
                x = W + 80 * Constants.SCALE, y = nil,   -- y filled on first draw
                velX = 0, velY = 0,
                delay = 0.05 + (i - 1) * 0.06,
                entering = true, alpha = 0,
            }
        end
    end

    HANDLERS.turn = function(s, d)
        s.turn = d
        s.turnAt = love.timer.getTime()
        if d then
            s.stage = d.stage or s.stage
            s.proposed = d.proposed or 0
            s.isOrdago = d.is_ordago or false
        end
    end

    HANDLERS.stage = function(s, d)
        s.stage = d.stage or s.stage
        if d.stage == "discard" then s.selected = {} end
    end

    HANDLERS.mus_said = function(s, d)
        s:say(s:nameOf(d.seat) .. (d.mus and ": mus" or ": ¡no hay mus!"))
        if AudioManager.playTap then AudioManager.playTap() end
    end

    HANDLERS.discard_chosen = function(s, d)
        s:say(s:nameOf(d.seat) .. " descarta " .. tostring(d.count))
    end

    HANDLERS.redrew = function(s, d) end

    HANDLERS.declarations = function(s, d)
        local yes = {}
        for _, e in ipairs(d.decl or {}) do
            if e.has then yes[#yes + 1] = s:nameOf(e.seat) end
        end
        local what = d.phase == "pares" and "pares" or "juego"
        if #yes == 0 then s:say("Nadie tiene " .. what)
        else s:say(what .. ": " .. table.concat(yes, ", ")) end
    end

    HANDLERS.bet_action = function(s, d)
        local who = s:nameOf(d.seat)
        if d.action == "envido" then
            s:say(who .. ": envido " .. tostring(d.amount) .. " (bote " .. tostring(d.proposed) .. ")")
        elseif d.action == "ordago" then
            s:say(who .. ": ¡ÓRDAGO!")
        else
            s:say(who .. ": " .. (ACTION_LABEL[d.action] or d.action):lower())
        end
    end

    HANDLERS.phase_result = function(s, d)
        if d.outcome == "rejected" then
            s:say((STAGE_LABEL[d.phase] or d.phase) .. ": no querido")
        elseif d.outcome == "accepted" then
            s:say((STAGE_LABEL[d.phase] or d.phase) .. ": querido, " .. tostring(d.amount))
        end
    end

    HANDLERS.score = function(s, d)
        s.scores = d.scores or s.scores
        local team = (d.team == s.myTeam) and "Nosotros" or "Ellos"
        s:say(team .. " +" .. tostring(d.piedras) .. " (" .. tostring(d.reason) .. ")")
    end

    HANDLERS.showdown = function(s, d)
        s.stage = "showdown"
        s.turn = nil
        s.revealed = {}
        for seat, cards in pairs(d.cards or {}) do
            s.revealed[tonumber(seat) or seat] = cards
        end
    end

    HANDLERS.hand_end = function(s, d)
        s.scores = d.scores or s.scores
        s.awards = d.awards
    end

    HANDLERS.game_end = function(s, d)
        s.gameOver = d
        s.turn = nil
    end

    HANDLERS.rewards = function(s, d) s.rewards = d end

    HANDLERS.state_snapshot = function(s, d)
        -- Reconnection: rebuild everything from the server's view.
        if d.players then
            s.players = {}
            for _, p in ipairs(d.players) do s.players[p.seat] = p end
        end
        s.mySeat = d.seat or s.mySeat
        s.myTeam = d.team or s.myTeam
        s.ranked = d.ranked or false
        local v = d.view
        if v then
            s.scores = v.scores or s.scores
            s.manoSeat = v.mano_seat or s.manoSeat
            s.handNo = v.hand_no or s.handNo
            s.myCards = v.my_cards or {}
            s.stage = v.stage or s.stage
            s.turn = v.turn
            s.turnAt = love.timer.getTime()
            s.proposed = v.proposed or 0
            s.isOrdago = v.is_ordago or false
            if v.all_cards then s.revealed = v.all_cards end
            if v.winner then s.gameOver = { winner_team = v.winner } end
        end
        s:say("Reconectado")
    end

    HANDLERS.seat_replaced = function(s, d)
        local oldName = s:nameOf(d.seat)
        if d.players then
            for _, p in ipairs(d.players) do s.players[p.seat] = p end
        end
        s:say(oldName .. " ahora es un bot")
    end

    HANDLERS.player_disconnected = function(s, d)
        s:say(s:nameOf(d.seat) .. " se ha desconectado")
    end

    HANDLERS.player_reconnected = function(s, d)
        s:say(s:nameOf(d.seat) .. " ha vuelto")
    end

    HANDLERS.emote = function(s, d)
        s:say(s:nameOf(d.seat) .. ": " .. tostring(d.emote))
    end

    HANDLERS.timed_out = function(s, d)
        s:say("Se te acabó el tiempo")
    end

    HANDLERS.action_rejected = function(s, d) end

    function self:sendAction(action)
        if self.localTable then
            self.localTable:send(action)
        elseif self.socket then
            self.socket:send("mus_action", { action = action })
        end
    end

    -- ── update ────────────────────────────────────────────────────────────────
    function self:update(dt)
        if self.localTable then
            self.localTable:update(dt)
        elseif self.socket then
            local ok = pcall(function() self.socket:update() end)
            if not ok then self:say("Conexión perdida...") end
        end

        -- Card enter animation (Balatro-style exponential smoother, same
        -- constants as the old AutoChest card hand).
        if self.cardAnims then
            for i, a in ipairs(self.cardAnims) do
                if a.entering and a.tx then
                    a.delay = a.delay - dt
                    if a.delay <= 0 then
                        local dx = a.tx - a.x
                        local dy = a.ty - a.y
                        local adt = math.min(dt, 1 / 30)
                        a.velX = a.velX * 0.004 + dx * 480 * adt
                        a.velY = a.velY * 0.004 + dy * 480 * adt
                        a.x = a.x + a.velX * adt
                        a.y = a.y + a.velY * adt
                        a.alpha = math.min(1, a.alpha + dt * 96)
                        local dist = math.sqrt(dx * dx + dy * dy)
                        if dist < 1 and math.abs(a.velX) < 5 and math.abs(a.velY) < 5 then
                            a.x, a.y = a.tx, a.ty
                            a.entering = false
                            a.alpha = 1
                        end
                    end
                end
            end
        end
    end

    function self:isMyTurn()
        if not self.turn or not self.turn.seats then return false end
        for _, s in ipairs(self.turn.seats) do
            if s == self.mySeat then return true end
        end
        return false
    end

    -- ── layout helpers ────────────────────────────────────────────────────────
    -- Relative seats: bottom = me, top = partner, right = next seat, left = prev.
    function self:seatAt(pos)
        local m = self.mySeat
        if pos == "bottom" then return m end
        if pos == "right" then return (m % 4) + 1 end
        if pos == "top" then return ((m + 1) % 4) + 1 end
        return ((m + 2) % 4) + 1   -- left
    end

    local function selectedCount(sel)
        local n = 0
        for _, v in pairs(sel) do if v then n = n + 1 end end
        return n
    end

    -- ── draw ──────────────────────────────────────────────────────────────────
    function self:draw()
        local lg = love.graphics
        local W, H = Constants.GAME_WIDTH, Constants.GAME_HEIGHT
        local sc = Constants.SCALE

        lg.clear(0.043, 0.235, 0.149)   -- tapete green

        self:drawScores(W, H, sc)
        self:drawOpponent("top", W, H, sc)
        self:drawOpponent("left", W, H, sc)
        self:drawOpponent("right", W, H, sc)
        self:drawCenter(W, H, sc)
        self:drawFeed(W, H, sc)
        self:drawMyHand(W, H, sc)
        self:drawButtons(W, H, sc)
        self:drawLeave(W, H, sc)

        if self.gameOver then self:drawGameOver(W, H, sc) end
        lg.setColor(1, 1, 1, 1)
    end

    function self:drawScores(W, H, sc)
        local lg = love.graphics
        local topY = math.floor(Constants.SAFE_INSET_TOP + 8 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(0.96, 0.84, 0.74, 1)
        lg.print("Nosotros " .. tostring(self.scores[self.myTeam] or 0), 12 * sc, topY)
        local other = (self.myTeam == 1) and 2 or 1
        local txt = "Ellos " .. tostring(self.scores[other] or 0)
        lg.print(txt, W - Fonts.small:getWidth(txt) - 12 * sc, topY)
    end

    function self:drawOpponent(pos, W, H, sc)
        local lg = love.graphics
        local seat = self:seatAt(pos)
        -- Same size as the player's own hand; side hands rotate ±90° so each
        -- player's cards face the center of the table.
        local cardW = 45 * math.max(1, math.floor((92 * sc) / 45 + 0.5))
        local cardH = CardRenderer.height(cardW)
        local cards = self.revealed and self.revealed[seat]
        -- Overlapped stack; spreads a little wider when revealed at showdown.
        local step = cards and math.floor(cardW * 0.52) or math.floor(cardW * 0.32)
        local span = cardW + 3 * step

        -- Center of the first card, per-card delta along the stack, rotation.
        local rot, cx, cy, dx, dy, nameX, nameY, nameW
        if pos == "top" then
            rot = 0
            cx = math.floor((W - span) / 2) + math.floor(cardW / 2)
            cy = math.floor(Constants.SAFE_INSET_TOP + 44 * sc) + math.floor(cardH / 2)
            dx, dy = step, 0
            nameX, nameW = cx - cardW / 2 - 40 * sc, span + 80 * sc
            nameY = cy + cardH / 2 + 4 * sc
        elseif pos == "left" then
            rot = math.pi / 2                     -- face right, toward the table
            cx = math.floor(cardH / 2 + 6 * sc)   -- rotated footprint is cardH wide
            cy = math.floor(H * 0.26) + math.floor(cardW / 2)
            dx, dy = 0, step
            nameX, nameW = 0, cardH + 24 * sc
            nameY = cy + (3 * step) + cardW / 2 + 6 * sc
        else
            rot = -math.pi / 2                    -- face left, toward the table
            cx = math.floor(W - cardH / 2 - 6 * sc)
            cy = math.floor(H * 0.26) + math.floor(cardW / 2)
            dx, dy = 0, step
            nameX, nameW = W - cardH - 24 * sc, cardH + 24 * sc
            nameY = cy + (3 * step) + cardW / 2 + 6 * sc
        end

        for i = 1, 4 do
            lg.push()
            lg.translate(cx + (i - 1) * dx, cy + (i - 1) * dy)
            lg.rotate(rot)
            if cards and cards[i] then
                CardRenderer.draw(cards[i], -math.floor(cardW / 2), -math.floor(cardH / 2), cardW)
            else
                CardRenderer.drawBack(-math.floor(cardW / 2), -math.floor(cardH / 2), cardW)
            end
            lg.pop()
        end

        -- Name plate: highlight on their turn; green when on my team.
        local isTurn = self.turn and self.turn.seats and self.turn.seats[1] == seat
        lg.setFont(Fonts.tiny)
        local name = self:nameOf(seat)
        if seat == self.manoSeat then name = name .. " (mano)" end
        local sameTeam = ((seat % 2 == 1) and 1 or 2) == self.myTeam
        if isTurn then lg.setColor(1, 0.9, 0.3, 1)
        elseif sameTeam then lg.setColor(0.75, 0.95, 0.75, 1)
        else lg.setColor(0.95, 0.8, 0.75, 1) end
        lg.printf(name, nameX, nameY, nameW, 'center')
    end

    function self:drawCenter(W, H, sc)
        local lg = love.graphics
        local label = STAGE_LABEL[self.stage] or ""
        if self.stage == "waiting" then label = "..." end
        local cy = math.floor(H * 0.42)
        if label ~= "" then
            lg.setFont(Fonts.large)
            lg.setColor(0.96, 0.84, 0.74, 0.95)
            lg.printf(label, 0, cy, W, 'center')
        end
        if self.isOrdago then
            lg.setFont(Fonts.small)
            lg.setColor(1, 0.5, 0.3, 1)
            lg.printf("¡ÓRDAGO EN JUEGO!", 0, cy + Fonts.large:getHeight() + 4 * sc, W, 'center')
        elseif self.proposed and self.proposed > 0 then
            lg.setFont(Fonts.small)
            lg.setColor(1, 0.9, 0.3, 1)
            lg.printf("bote: " .. tostring(self.proposed), 0, cy + Fonts.large:getHeight() + 4 * sc, W, 'center')
        end

        -- Turn line + countdown (server enforces 25s; no timeout in sandbox).
        if self.turn and self.turn.seats and #self.turn.seats > 0 then
            local who = self.turn.seats[1]
            lg.setFont(Fonts.tiny)
            lg.setColor(0.76, 0.64, 0.54, 0.9)
            local whoTxt = self:isMyTurn() and "tu turno" or ("turno de " .. self:nameOf(who))
            if not self.isSandbox then
                local remain = math.max(0, 25 - (love.timer.getTime() - self.turnAt))
                whoTxt = whoTxt .. "  ·  " .. tostring(math.ceil(remain)) .. "s"
            end
            lg.printf(whoTxt, 0, cy - Fonts.tiny:getHeight() - 6 * sc, W, 'center')
        end
    end

    function self:drawFeed(W, H, sc)
        local lg = love.graphics
        lg.setFont(Fonts.tiny)
        local y = math.floor(H * 0.52)
        for i, line in ipairs(self.feed) do
            local age = love.timer.getTime() - line.at
            local alpha = math.max(0.25, 1 - age / 10)
            lg.setColor(1, 1, 1, alpha)
            lg.printf(line.text, 20 * sc, y + (i - 1) * (Fonts.tiny:getHeight() + 3 * sc), W - 40 * sc, 'center')
        end
    end

    function self:drawMyHand(W, H, sc)
        local lg = love.graphics
        -- Pixel-snap: width is an integer multiple of the 45px sprite so the
        -- pixel art scales crisply (nearest filter, no fractional pixels).
        local cardW = 45 * math.max(1, math.floor((92 * sc) / 45 + 0.5))
        local gap = math.floor(10 * sc)
        local totalW = 4 * cardW + 3 * gap
        local x0 = math.floor((W - totalW) / 2)
        local baseY = math.floor(H - Constants.SAFE_INSET_BOTTOM - CardRenderer.height(cardW) - 26 * sc)
        self._handRects = {}

        for i, card in ipairs(self.myCards) do
            local x = x0 + (i - 1) * (cardW + gap)
            local y = baseY
            if self.selected[i] then y = y - math.floor(18 * sc) end

            -- Enter animation: draw at the animated position until settled.
            local a = self.cardAnims and self.cardAnims[i]
            local drawX, drawY, alpha = x, y, 1
            local waiting = false
            if a then
                a.tx, a.ty = x, y
                if a.y == nil then a.y = y end
                if a.entering then
                    if a.delay > 0 then
                        waiting = true   -- not dealt yet
                    else
                        drawX, drawY, alpha = math.floor(a.x), math.floor(a.y), a.alpha
                    end
                end
            end

            if not waiting then
                lg.setColor(1, 1, 1, alpha)
                CardRenderer.draw(card, drawX, drawY, cardW, alpha)
                if self.selected[i] then
                    lg.setColor(1, 0.85, 0.2, 1)
                    lg.setLineWidth(math.max(2, 2 * sc))
                    lg.rectangle("line", drawX, drawY, cardW, CardRenderer.height(cardW),
                        math.floor(cardW * 0.09), math.floor(cardW * 0.09))
                end
            end
            self._handRects[i] = { x = x, y = y, w = cardW, h = CardRenderer.height(cardW) }
        end

        -- My name plate under the hand
        lg.setFont(Fonts.tiny)
        lg.setColor(0.75, 0.95, 0.75, 1)
        local label = "Tú"
        if self.mySeat == self.manoSeat then label = label .. " (mano)" end
        lg.printf(label, 0, H - Constants.SAFE_INSET_BOTTOM - 18 * sc, W, 'center')
    end

    -- Contextual action buttons from the server's turn options.
    function self:drawButtons(W, H, sc)
        local lg = love.graphics
        self.buttons = {}
        if self.gameOver or not self:isMyTurn() then return end
        local opts = self.turn.options or {}

        local defs = {}
        for _, opt in ipairs(opts) do
            if opt == "discard" then
                local n = selectedCount(self.selected)
                defs[#defs + 1] = { id = "discard", label = "Descartar " .. n, enabled = n > 0 }
            elseif opt == "envido" then
                local raising = (self.turn.proposed or 0) > 0
                defs[#defs + 1] = { id = "envido", label = raising and "Subir 2" or "Envido 2", enabled = true }
            else
                defs[#defs + 1] = { id = opt, label = ACTION_LABEL[opt] or opt, enabled = true }
            end
        end
        if #defs == 0 then return end

        local btnH = math.floor(52 * sc)
        local gap = math.floor(8 * sc)
        local margin = math.floor(12 * sc)
        local btnW = math.floor((W - margin * 2 - gap * (#defs - 1)) / #defs)
        local cardH = CardRenderer.height(math.floor(92 * sc))
        local y = math.floor(H - Constants.SAFE_INSET_BOTTOM - cardH - 26 * sc - btnH - 14 * sc)

        for i, def in ipairs(defs) do
            local x = margin + (i - 1) * (btnW + gap)
            local pressed = (self._pressedBtn == def.id)
            local dy = pressed and math.floor(2 * sc) or 0

            lg.setColor(0.031, 0.078, 0.118, 1)
            lg.rectangle("fill", x + 2, y + 4, btnW, btnH, 8, 8)
            if not def.enabled then lg.setColor(0.35, 0.35, 0.38, 1)
            elseif def.id == "ordago" then lg.setColor(0.65, 0.25, 0.20, 1)
            elseif def.id == "quiero" or def.id == "mus" then lg.setColor(0.15, 0.40, 0.30, 1)
            else lg.setColor(0.13, 0.25, 0.38, 1) end
            lg.rectangle("fill", x, y + dy, btnW, btnH, 8, 8)
            lg.setColor(1, 1, 1, def.enabled and 1 or 0.5)
            local font = (btnW < 110 * sc) and Fonts.tiny or Fonts.small
            lg.setFont(font)
            lg.printf(def.label, x, y + dy + math.floor((btnH - font:getHeight()) / 2), btnW, 'center')

            self.buttons[#self.buttons + 1] = { id = def.id, x = x, y = y, w = btnW, h = btnH, enabled = def.enabled }
        end
    end

    function self:drawLeave(W, H, sc)
        local lg = love.graphics
        local size = math.floor(30 * sc)
        local x = W - size - math.floor(8 * sc)
        local y = math.floor(Constants.SAFE_INSET_TOP + 6 * sc)
        lg.setFont(Fonts.tiny)
        if self.leaveArmed then
            local txt = "¿Salir? Toca otra vez"
            local tw = Fonts.tiny:getWidth(txt)
            lg.setColor(1, 0.5, 0.4, 1)
            lg.print(txt, x + size - tw, y + size + 2 * sc)
        end
        lg.setColor(1, 1, 1, 0.55)
        lg.printf("X", x, y + math.floor((size - Fonts.tiny:getHeight()) / 2), size, 'center')
        lg.setLineWidth(1)
        lg.setColor(1, 1, 1, 0.35)
        lg.rectangle("line", x, y, size, size, 6, 6)
        self._leaveRect = { x = x - 6 * sc, y = y - 6 * sc, w = size + 12 * sc, h = size + 12 * sc }
    end

    function self:drawGameOver(W, H, sc)
        local lg = love.graphics
        lg.setColor(0, 0, 0, 0.75)
        lg.rectangle("fill", 0, 0, W, H)
        local won = self.gameOver.winner_team == self.myTeam
        lg.setFont(Fonts.large)
        if won then lg.setColor(0.4, 1, 0.4, 1) else lg.setColor(1, 0.45, 0.4, 1) end
        lg.printf(won and "¡HABÉIS GANADO!" or "HABÉIS PERDIDO", 0, H * 0.38, W, 'center')
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 0.9)
        if self.gameOver.ordago then
            lg.printf("por órdago", 0, H * 0.38 + Fonts.large:getHeight() + 8 * sc, W, 'center')
        end
        if self.rewards and self.rewards.trophy_delta then
            local sign = self.rewards.trophy_delta >= 0 and "+" or ""
            lg.printf(sign .. tostring(self.rewards.trophy_delta) .. " trofeos", 0, H * 0.50, W, 'center')
        end
        lg.setFont(Fonts.tiny)
        lg.setColor(0.8, 0.8, 0.8, 0.9)
        lg.printf("Toca para volver al menú", 0, H * 0.62, W, 'center')
    end

    -- ── input ─────────────────────────────────────────────────────────────────
    local function inRect(x, y, r)
        return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
    end

    function self:goToMenu()
        if self.socket and not self.gameOver then
            pcall(function() self.socket:send("leave_table", {}) end)
        end
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('menu', true)
    end

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end
        for _, b in ipairs(self.buttons) do
            if b.enabled and inRect(x, y, b) then
                self._pressedBtn = b.id
                return
            end
        end
    end

    function self:mousereleased(x, y, button)
        if button ~= 1 then return end
        local pressed = self._pressedBtn
        self._pressedBtn = nil

        if self.gameOver then
            self:goToMenu()
            return
        end

        -- Leave (double-tap to confirm)
        if inRect(x, y, self._leaveRect) then
            if self.leaveArmed then
                self:goToMenu()
            else
                self.leaveArmed = true
            end
            return
        end
        self.leaveArmed = false

        -- Action buttons
        for _, b in ipairs(self.buttons) do
            if b.enabled and inRect(x, y, b) and pressed == b.id then
                if AudioManager.playTap then AudioManager.playTap() end
                if b.id == "discard" then
                    local indices = {}
                    for i = 1, 4 do
                        if self.selected[i] then indices[#indices + 1] = i end
                    end
                    self:sendAction({ type = "discard", indices = indices })
                    self.selected = {}
                elseif b.id == "envido" then
                    self:sendAction({ type = "envido", amount = 2 })
                else
                    self:sendAction({ type = b.id })
                end
                return
            end
        end

        -- Card selection during the discard stage
        if self.stage == "discard" and self:isMyTurn() and self._handRects then
            for i, r in ipairs(self._handRects) do
                if inRect(x, y, r) then
                    if self.selected[i] then self.selected[i] = nil
                    else self.selected[i] = true end
                    return
                end
            end
        end
    end

    function self:touchpressed(_, x, y) self:mousepressed(x, y, 1) end
    function self:touchreleased(_, x, y) self:mousereleased(x, y, 1) end

    function self:close()
        if self.socket then
            if self._cb_gameEvent then pcall(function() self.socket:removeCallback(self._cb_gameEvent) end) end
            if self._cb_currency then pcall(function() self.socket:removeCallback(self._cb_currency) end) end
        end
        _G.TableInfo = nil
    end

    return self
end

return GameScreen
