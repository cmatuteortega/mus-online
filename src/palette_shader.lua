-- 12-color palette-snap shader. Every opaque pixel is clamped to the nearest
-- colour in the project palette. Used two ways:
--   1. Globally, applied to the whole frame at Push:finish (main.lua) so the
--      entire project — backgrounds, UI, text, and card sprites — is limited
--      to the palette.
--   2. Per-sprite (menu/lobby/transition clouds); idempotent with the global
--      pass since a pixel already on-palette snaps to itself.
--
-- Palette (hex → linear order matches Constants.PALETTE):
--   #dfe6e0 #d9c277 #c17b5c #85444a #4a363c #9ba15f
--   #596e47 #38453a #a9bbcc #7687ab #444a65 #222228

local _paletteShader = nil

local PaletteShader = {}

-- Master toggle for the palette-snap pass. When false, get() returns nil so
-- both the whole-frame clamp (main.lua Push:finish) and per-sprite passes fall
-- back to no shader. Flip to true to re-enable. The GLSL below is left intact.
PaletteShader.enabled = false

function PaletteShader.get()
    if not PaletteShader.enabled then return nil end
    if not _paletteShader then
        _paletteShader = love.graphics.newShader([[
            vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
                vec4 pixel = Texel(texture, texture_coords);
                if (pixel.a < 0.01) { return pixel; }
                vec3 pal[12];
                pal[0]  = vec3(0.8745, 0.9020, 0.8784); // #dfe6e0
                pal[1]  = vec3(0.8510, 0.7608, 0.4667); // #d9c277
                pal[2]  = vec3(0.7569, 0.4824, 0.3608); // #c17b5c
                pal[3]  = vec3(0.5216, 0.2667, 0.2902); // #85444a
                pal[4]  = vec3(0.2902, 0.2118, 0.2353); // #4a363c
                pal[5]  = vec3(0.6078, 0.6314, 0.3725); // #9ba15f
                pal[6]  = vec3(0.3490, 0.4314, 0.2784); // #596e47
                pal[7]  = vec3(0.2196, 0.2706, 0.2275); // #38453a
                pal[8]  = vec3(0.6627, 0.7333, 0.8000); // #a9bbcc
                pal[9]  = vec3(0.4627, 0.5294, 0.6706); // #7687ab
                pal[10] = vec3(0.2667, 0.2902, 0.3961); // #444a65
                pal[11] = vec3(0.1333, 0.1333, 0.1569); // #222228
                vec3 best = pal[0];
                float bd = dot(pixel.rgb - pal[0], pixel.rgb - pal[0]);
                for (int i = 1; i < 12; i++) {
                    vec3 diff = pixel.rgb - pal[i];
                    float d = dot(diff, diff);
                    if (d < bd) { bd = d; best = pal[i]; }
                }
                return vec4(best, pixel.a) * color;
            }
        ]])
    end
    return _paletteShader
end

return PaletteShader
