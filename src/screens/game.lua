-- Placeholder game screen for the mus migration (MUS_MIGRATION_PLAN.md, Phase 0).
-- Receives the lobby handoff with the old signature so matchmaking end-to-end
-- still works: shows who you matched with, keeps the socket alive, and returns
-- to the menu on tap. Replaced by the real mus table in Phase 3.

local Screen        = require('lib.screen')
local Constants     = require('src.constants')

local GameScreen = {}

function GameScreen.new()
    local self = Screen.new()

    function self:init(isOnline, playerRole, socket)
        self.isOnline   = isOnline or false
        self.playerRole = playerRole or 1
        self.socket     = socket
        self.opponentGone = false

        if self.socket then
            self.socket:on("opponent_disconnected", function()
                self.opponentGone = true
            end)
        end
    end

    function self:update(dt)
        -- Keep pumping ENet so the connection survives until we leave.
        if self.socket then
            pcall(function() self.socket:update() end)
        end
    end

    function self:draw()
        local W, H = Constants.GAME_WIDTH, Constants.GAME_HEIGHT
        love.graphics.clear(0.03, 0.08, 0.12)

        love.graphics.setFont(Fonts.large)
        love.graphics.setColor(0.96, 0.84, 0.74)
        love.graphics.printf("MUS", 0, H * 0.30, W, "center")

        love.graphics.setFont(Fonts.small)
        love.graphics.setColor(0.76, 0.64, 0.54)
        local me  = (_G.PlayerData and _G.PlayerData.username) or "You"
        local opp = (_G.OpponentData and _G.OpponentData.name) or "?"
        love.graphics.printf("Match found: " .. me .. " vs " .. opp, 0, H * 0.42, W, "center")
        love.graphics.printf("Game table coming in Phase 3", 0, H * 0.48, W, "center")
        if self.opponentGone then
            love.graphics.printf("(opponent disconnected)", 0, H * 0.54, W, "center")
        end

        love.graphics.setFont(Fonts.tiny)
        love.graphics.printf("Tap to return to menu", 0, H * 0.80, W, "center")
        love.graphics.setColor(1, 1, 1)
    end

    local function leave()
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('menu', true)
    end

    function self:mousereleased() leave() end
    function self:touchreleased() leave() end

    function self:close() end

    return self
end

return GameScreen
