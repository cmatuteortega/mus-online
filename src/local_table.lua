-- Sandbox table: runs the mus engine locally (you at seat 1 + 3 bots), no
-- server needed. Reuses the same shared engine and bot the server runs, and
-- feeds the game screen the exact same events it would get online.

local MusEngine = require('shared.mus_engine')
local Bot       = require('shared.mus_bot')

local BOT_DELAY       = 1.2
local NEXT_HAND_DELAY = 4.0

local LocalTable = {}

-- onEvent(name, data) receives every event visible to seat 1.
function LocalTable.new(onEvent)
    local self = {
        match = MusEngine.newMatch({}, os.time()),
        onEvent = onEvent,
        botClock = BOT_DELAY,
        nextHandClock = nil,
        done = false,
    }

    function self:dispatch(events)
        for _, e in ipairs(events or {}) do
            if e.to == "all" or e.to == 1 then self.onEvent(e.name, e.data) end
        end
    end

    function self:afterStep()
        self.botClock = BOT_DELAY
        if self.match.winner then
            self.done = true
        elseif self.match.hand and self.match.hand.stage == "showdown" then
            self.nextHandClock = NEXT_HAND_DELAY
        end
    end

    function self:start()
        self:dispatch(MusEngine.startHand(self.match))
        self:afterStep()
    end

    -- The player's intent (same action tables as the online protocol).
    function self:send(action)
        if self.done then return end
        local ok, res = MusEngine.apply(self.match, 1, action)
        if ok then
            self:dispatch(res)
            self:afterStep()
        else
            self.onEvent("action_rejected", { reason = res })
        end
    end

    function self:update(dt)
        if self.done then return end
        if self.nextHandClock then
            self.nextHandClock = self.nextHandClock - dt
            if self.nextHandClock <= 0 then
                self.nextHandClock = nil
                self:dispatch(MusEngine.startHand(self.match))
                self:afterStep()
            end
            return
        end
        -- Let any pending bot seat act (the player acts through send()).
        local seats = MusEngine.pendingSeats(self.match)
        local botSeat = nil
        for _, s in ipairs(seats) do
            if s ~= 1 then botSeat = s break end
        end
        if botSeat then
            self.botClock = self.botClock - dt
            if self.botClock <= 0 then
                local ok, res = MusEngine.apply(self.match, botSeat, Bot.decide(self.match, botSeat))
                if ok then self:dispatch(res) end
                self:afterStep()
            end
        end
    end

    return self
end

function LocalTable.roster()
    local out = {}
    for seat = 1, 4 do
        out[#out + 1] = {
            seat = seat, team = (seat % 2 == 1) and 1 or 2,
            username = (seat == 1) and ((_G.PlayerData and _G.PlayerData.username) or "Tú")
                        or Bot.pickName(seat),
            trophies = 0, is_bot = seat ~= 1, connected = seat == 1,
        }
    end
    return out
end

return LocalTable
