-- Client-side persisted game-rule preferences that drive matchmaking.
-- The player edits these from the menu's "Reglas" modal; they are saved to
-- game_settings.json so the choices survive app restarts, and sent to the
-- server on queue join so players only match with others using the same rules.
--
--   reyes8  false = 4 kings (BASE) · true = 8 kings (3s count as kings, 2s as aces)
--   emotes  false = no emotes (BASE) · true = table-talk emotes allowed
--   bestOf  1 | 3 (BASE) | 5 — sets played to 40 piedras; first to a majority wins
--
-- Base queue = 4 kings, no emotes, best of 3.

local json   = require('lib.json')
local Locale = require('src.locale')

local FILE = "game_settings.json"

local GameSettings = {
    reyes8 = false,
    emotes = false,
    bestOf = 3,
}

local BEST_OF_ALLOWED = { [1] = true, [3] = true, [5] = true }

function GameSettings.load()
    local raw = love.filesystem.read(FILE)
    if not raw then return end
    local ok, t = pcall(json.decode, raw)
    if ok and type(t) == "table" then
        GameSettings.reyes8 = t.reyes8 == true
        GameSettings.emotes = t.emotes == true
        if BEST_OF_ALLOWED[t.bestOf] then GameSettings.bestOf = t.bestOf end
    end
end

function GameSettings.save()
    local ok, data = pcall(json.encode, {
        reyes8 = GameSettings.reyes8,
        emotes = GameSettings.emotes,
        bestOf = GameSettings.bestOf,
    })
    if ok then love.filesystem.write(FILE, data) end
end

-- Settings payload sent to the server alongside a queue-join intent.
function GameSettings.payload()
    return {
        reyes8 = GameSettings.reyes8,
        emotes = GameSettings.emotes,
        bestOf = GameSettings.bestOf,
    }
end

-- Short human summary shown above the PLAY button (localized to the UI language).
function GameSettings.summary()
    local kings = GameSettings.reyes8 and Locale.t("rules.k8") or Locale.t("rules.k4")
    local em    = GameSettings.emotes and Locale.t("rules.emotes_on") or Locale.t("rules.emotes_off")
    local bo    = Locale.t("rules.best_of", GameSettings.bestOf)
    return kings .. "  ·  " .. em .. "  ·  " .. bo
end

GameSettings.load()

return GameSettings
