-- 8-color palette-snap shader, extracted from the old BaseUnit when the unit
-- system was removed. Used by menu/lobby to keep sprites on the game palette.

local _paletteShader = nil

local PaletteShader = {}

function PaletteShader.get()
    if not _paletteShader then
        _paletteShader = love.graphics.newShader([[
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
    return _paletteShader
end

return PaletteShader
