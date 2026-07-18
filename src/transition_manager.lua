-- Cloud curtain transition. Sweeps cloud sprites in to obscure the screen,
-- fires a callback at full coverage (where the screen swap happens), then
-- sweeps them out to reveal the new scene.

local Constants = require('src.constants')

local TransitionManager = {}

local NUM_CLOUDS       = 11
local COVER_DURATION   = 0.45
local HOLD_DURATION    = 0.10
local REVEAL_DURATION  = 0.45
local NUM_SPRITES      = 6

local images   = {}
local state    = "idle"
local timer    = 0
local clouds   = {}
local pendingCallback = nil
local paletteShader = nil

local function getPaletteShader()
    if not paletteShader then
        paletteShader = love.graphics.newShader([[
            vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
                vec4 pixel = Texel(texture, texture_coords);
                if (pixel.a < 0.01) { return pixel; }
                vec3 c0 = vec3(0.0314, 0.0784, 0.1176);
                vec3 c1 = vec3(0.0588, 0.1647, 0.2471);
                vec3 c2 = vec3(0.1255, 0.2235, 0.3098);
                vec3 c3 = vec3(0.9647, 0.8392, 0.7412);
                vec3 c4 = vec3(0.7647, 0.6392, 0.5412);
                vec3 c5 = vec3(0.6000, 0.4588, 0.4667);
                vec3 c6 = vec3(0.5059, 0.3843, 0.4431);
                vec3 c7 = vec3(0.3059, 0.2863, 0.3725);
                float d0 = dot(pixel.rgb - c0, pixel.rgb - c0);
                float d1 = dot(pixel.rgb - c1, pixel.rgb - c1);
                float d2 = dot(pixel.rgb - c2, pixel.rgb - c2);
                float d3 = dot(pixel.rgb - c3, pixel.rgb - c3);
                float d4 = dot(pixel.rgb - c4, pixel.rgb - c4);
                float d5 = dot(pixel.rgb - c5, pixel.rgb - c5);
                float d6 = dot(pixel.rgb - c6, pixel.rgb - c6);
                float d7 = dot(pixel.rgb - c7, pixel.rgb - c7);
                vec3 best = c0; float bd = d0;
                if (d1 < bd) { bd = d1; best = c1; }
                if (d2 < bd) { bd = d2; best = c2; }
                if (d3 < bd) { bd = d3; best = c3; }
                if (d4 < bd) { bd = d4; best = c4; }
                if (d5 < bd) { bd = d5; best = c5; }
                if (d6 < bd) { bd = d6; best = c6; }
                if (d7 < bd) { best = c7; }
                return vec4(best, pixel.a) * color;
            }
        ]])
    end
    return paletteShader
end

local function easeOutCubic(t)
    local u = 1 - t
    return 1 - u * u * u
end

local function easeInCubic(t)
    return t * t * t
end

function TransitionManager.init()
    for i = 1, NUM_SPRITES do
        local img = love.graphics.newImage("src/assets/clouds/cloud" .. i .. ".png")
        img:setFilter('nearest', 'nearest')
        images[i] = img
    end
end

local function buildClouds()
    clouds = {}
    local W = Constants.GAME_WIDTH
    local H = Constants.GAME_HEIGHT
    local travelDist = math.max(W, H) * 1.5

    -- 5-row scatter that fully covers 540x960 with no gaps on any edge.
    local restAnchors = {
        { x = W * 0.15, y = H * 0.08 },
        { x = W * 0.55, y = H * 0.05 },
        { x = W * 0.90, y = H * 0.10 },
        { x = W * 0.22, y = H * 0.30 },
        { x = W * 0.78, y = H * 0.32 },
        { x = W * 0.50, y = H * 0.50 },
        { x = W * 0.18, y = H * 0.70 },
        { x = W * 0.82, y = H * 0.68 },
        { x = W * 0.12, y = H * 0.92 },
        { x = W * 0.50, y = H * 0.95 },
        { x = W * 0.88, y = H * 0.90 },
    }

    for i = 1, NUM_CLOUDS do
        local anchor = restAnchors[i]
        local restX = anchor.x + (love.math.random() - 0.5) * 80
        local restY = anchor.y + (love.math.random() - 0.5) * 80

        local enterAngle = (love.math.random() < 0.5) and 0 or math.pi
        local exitAngle  = (love.math.random() < 0.5) and 0 or math.pi

        local img = images[love.math.random(1, NUM_SPRITES)]
        local imgW, imgH = img:getWidth(), img:getHeight()
        local targetWidth = W * (0.50 + love.math.random() * 0.15) * 2
        local scale = targetWidth / imgW

        clouds[i] = {
            image       = img,
            scale       = scale,
            imgW        = imgW,
            imgH        = imgH,
            restX       = restX,
            restY       = restY,
            enterX      = restX + math.cos(enterAngle) * travelDist,
            enterY      = restY + math.sin(enterAngle) * travelDist,
            exitX       = restX + math.cos(exitAngle)  * travelDist,
            exitY       = restY + math.sin(exitAngle)  * travelDist,
            wobblePhase = love.math.random() * math.pi * 2,
            wobbleAmp   = 4 + love.math.random() * 6,
        }
    end
end

function TransitionManager.cloudCurtain(callback)
    if state ~= "idle" then return end
    buildClouds()
    pendingCallback = callback
    state = "covering"
    timer = 0
end

function TransitionManager.update(dt)
    if state == "idle" then return end

    -- Cap dt so a long frame stall (mobile menu init can block the main
    -- thread for hundreds of ms) doesn't blow through swap+reveal in one
    -- tick, which would make the clouds snap to invisible.
    if dt > 1/30 then dt = 1/30 end

    timer = timer + dt

    if state == "covering" then
        if timer >= COVER_DURATION then
            timer = timer - COVER_DURATION
            state = "swap"
            if pendingCallback then
                local cb = pendingCallback
                pendingCallback = nil
                cb()
            end
        end
    elseif state == "swap" then
        if timer >= HOLD_DURATION then
            timer = timer - HOLD_DURATION
            state = "revealing"
        end
    elseif state == "revealing" then
        if timer >= REVEAL_DURATION then
            timer  = 0
            state  = "idle"
            clouds = {}
        end
    end
end

function TransitionManager.draw()
    if state == "idle" then return end

    love.graphics.setColor(1, 1, 1, 1)
    local prevShader = love.graphics.getShader()
    love.graphics.setShader(getPaletteShader())

    for _, c in ipairs(clouds) do
        local x, y

        if state == "covering" then
            local p = easeOutCubic(math.min(1, timer / COVER_DURATION))
            x = c.enterX + (c.restX - c.enterX) * p
            y = c.enterY + (c.restY - c.enterY) * p
        elseif state == "swap" then
            local t = c.wobblePhase + timer * 6
            x = c.restX + math.sin(t) * c.wobbleAmp
            y = c.restY + math.cos(t) * c.wobbleAmp
        else
            local p = easeInCubic(math.min(1, timer / REVEAL_DURATION))
            x = c.restX + (c.exitX - c.restX) * p
            y = c.restY + (c.exitY - c.restY) * p
        end

        love.graphics.draw(c.image, x, y, 0, c.scale, c.scale, c.imgW / 2, c.imgH / 2)
    end

    love.graphics.setShader(prevShader)
end

function TransitionManager.isActive()
    return state ~= "idle"
end

return TransitionManager
