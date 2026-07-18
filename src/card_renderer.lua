-- Spanish-deck card rendering. Uses sprite files if present, otherwise draws
-- a clean procedural card so the game is fully playable without art.
--
-- Sprite naming follows the musatro convention so its sprites drop straight in:
--   src/assets/cards/<value>_<suit>.png   value 1-7, 11 sota, 12 caballo, 13 rey
--   src/assets/cards/back.png
-- (engine ranks are 1-7, 10, 11, 12 — figures map to sprite values 11/12/13)

local CardRenderer = {}

local SPRITE_W, SPRITE_H = 45, 58   -- source sprite size (musatro)

local sprites = {}       -- "value_suit" → Image
local backSprite = nil
local loaded = false

local SUIT_COLORS = {
    oros    = { 0.85, 0.68, 0.18 },
    copas   = { 0.75, 0.22, 0.22 },
    espadas = { 0.25, 0.45, 0.75 },
    bastos  = { 0.30, 0.60, 0.32 },
}

local SUIT_LETTER = { oros = "O", copas = "C", espadas = "E", bastos = "B" }
local FIGURE_NAME = { [10] = "S", [11] = "C", [12] = "R" }   -- sota/caballo/rey

local function spriteValue(rank)
    if rank <= 7 then return rank end
    return rank + 1   -- 10→11, 11→12, 12→13
end

function CardRenderer.load()
    if loaded then return end
    loaded = true
    local lf = love.filesystem
    if lf.getInfo("src/assets/cards/back.png") then
        backSprite = love.graphics.newImage("src/assets/cards/back.png")
        backSprite:setFilter("nearest", "nearest")
    end
    local suits = { "oros", "copas", "espadas", "bastos" }
    for _, suit in ipairs(suits) do
        for _, rank in ipairs({ 1, 2, 3, 4, 5, 6, 7, 10, 11, 12 }) do
            local v = spriteValue(rank)
            local path = string.format("src/assets/cards/%d_%s.png", v, suit)
            if lf.getInfo(path) then
                local img = love.graphics.newImage(path)
                img:setFilter("nearest", "nearest")
                sprites[v .. "_" .. suit] = img
            end
        end
    end
end

CardRenderer.ASPECT = SPRITE_H / SPRITE_W

-- Draw a face-up card with top-left at (x, y), width w (height follows aspect).
-- alpha is optional (used by deal-in animations).
function CardRenderer.draw(card, x, y, w, alpha)
    local lg = love.graphics
    local h = math.floor(w * CardRenderer.ASPECT)
    local sprite = sprites[spriteValue(card.rank) .. "_" .. card.suit]
    if sprite then
        lg.setColor(1, 1, 1, alpha or 1)
        lg.draw(sprite, x, y, 0, w / SPRITE_W, h / SPRITE_H)
        return h
    end
    -- Procedural fallback
    local r = math.max(2, math.floor(w * 0.09))
    lg.setColor(0.05, 0.08, 0.10, 1)
    lg.rectangle("fill", x + 2, y + 3, w, h, r, r)
    lg.setColor(0.94, 0.92, 0.86, 1)
    lg.rectangle("fill", x, y, w, h, r, r)
    local col = SUIT_COLORS[card.suit] or { 0.2, 0.2, 0.2 }
    lg.setColor(col[1], col[2], col[3], 1)
    lg.setLineWidth(math.max(1, math.floor(w * 0.03)))
    lg.rectangle("line", x, y, w, h, r, r)

    local label = FIGURE_NAME[card.rank] or tostring(card.rank)
    local fontSmall = Fonts.tiny
    local fontBig   = (w >= 60) and Fonts.large or Fonts.medium
    lg.setFont(fontSmall)
    lg.print(label, x + math.floor(w * 0.08), y + math.floor(h * 0.05))
    lg.setFont(fontBig)
    local bw = fontBig:getWidth(label)
    lg.print(label, x + math.floor((w - bw) / 2), y + math.floor(h * 0.26))
    lg.setFont(fontSmall)
    local suitStr = SUIT_LETTER[card.suit]
    local sw = fontSmall:getWidth(suitStr)
    lg.print(suitStr, x + w - sw - math.floor(w * 0.08), y + h - fontSmall:getHeight() - math.floor(h * 0.05))
    return h
end

-- Draw a face-down card.
function CardRenderer.drawBack(x, y, w)
    local lg = love.graphics
    local h = math.floor(w * CardRenderer.ASPECT)
    if backSprite then
        lg.setColor(1, 1, 1, 1)
        lg.draw(backSprite, x, y, 0, w / SPRITE_W, h / SPRITE_H)
        return h
    end
    local r = math.max(2, math.floor(w * 0.09))
    lg.setColor(0.05, 0.08, 0.10, 1)
    lg.rectangle("fill", x + 2, y + 3, w, h, r, r)
    lg.setColor(0.23, 0.28, 0.45, 1)
    lg.rectangle("fill", x, y, w, h, r, r)
    lg.setColor(0.33, 0.38, 0.58, 1)
    lg.setLineWidth(math.max(1, math.floor(w * 0.03)))
    lg.rectangle("line", x + math.floor(w * 0.10), y + math.floor(h * 0.08),
        w - math.floor(w * 0.20), h - math.floor(h * 0.16), r, r)
    return h
end

function CardRenderer.height(w)
    return math.floor(w * CardRenderer.ASPECT)
end

return CardRenderer
