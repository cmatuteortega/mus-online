-- AudioManager: singleton for music and SFX management
-- Usage: AudioManager = require('src.audio_manager')  (loaded globally in main.lua)

local json = require('lib.json')

local AM = {
    musicEnabled = true,
    sfxEnabled   = true,
    _music       = nil,   -- streaming Source for OST
    _taps        = {},    -- 3 static Sources for UI taps
    _sfx         = {},    -- cache: filename → static Source
    _battleMode  = false,
    _wasMusicPlaying = false,  -- tracks music state across focus loss/gain
}

local SETTINGS_FILE = "settings.json"

-- ── persistence ───────────────────────────────────────────────────────────────

local function loadSettings()
    local data = love.filesystem.read(SETTINGS_FILE)
    if data then
        local ok, t = pcall(function() return json.decode(data) end)
        if ok and type(t) == "table" then
            if t.music ~= nil then AM.musicEnabled = t.music end
            if t.sfx   ~= nil then AM.sfxEnabled   = t.sfx   end
        end
    end
end

function AM.save()
    local ok, data = pcall(json.encode, {music = AM.musicEnabled, sfx = AM.sfxEnabled})
    if ok then love.filesystem.write(SETTINGS_FILE, data) end
end

-- ── init ──────────────────────────────────────────────────────────────────────

function AM.init()
    loadSettings()

    -- Streaming source for OST (saves memory for long track)
    AM._music = love.audio.newSource("src/audio/ost.mp3", "stream")
    AM._music:setLooping(true)
    AM._music:setVolume(0.2)

    -- Static sources for tap SFX (short, played frequently)
    for i = 1, 3 do
        local src = love.audio.newSource("src/audio/tap" .. i .. ".mp3", "static")
        src:setVolume(1)
        AM._taps[i] = src
    end
end

-- ── music ─────────────────────────────────────────────────────────────────────

function AM.playMusic()
    if not AM.musicEnabled then return end
    if AM._music and not AM._music:isPlaying() then
        AM._music:play()
    end
end

function AM.stopMusic()
    if AM._music and AM._music:isPlaying() then
        AM._music:stop()
    end
end

-- ── battle mode (low-pass filter) ─────────────────────────────────────────────

function AM.setBattleMode(enabled)
    if AM._battleMode == enabled then return end
    AM._battleMode = enabled
    if AM._music then
        if enabled then
            AM._music:setFilter({type = "lowpass", volume = 1.0, highgain = 0.08})
        else
            AM._music:setFilter({type = "lowpass", volume = 1.0, highgain = 1.0})
        end
    end
end

-- ── SFX ───────────────────────────────────────────────────────────────────────

function AM.playTap()
    if not AM.sfxEnabled then return end
    local src = AM._taps[love.math.random(1, 3)]
    if src then
        -- Clone so rapid taps can overlap
        local clone = src:clone()
        clone:play()
    end
end

function AM.playSFX(name, volume)
    if not AM.sfxEnabled then return end
    if not AM._sfx[name] then
        AM._sfx[name] = love.audio.newSource("src/audio/" .. name, "static")
    end
    local clone = AM._sfx[name]:clone()
    clone:setVolume(volume or 0.5)
    clone:play()
end

-- ── focus pause / resume (background handling) ──────────────────────────────

function AM.pauseAll()
    if AM._music and AM._music:isPlaying() then
        AM._wasMusicPlaying = true
        AM._music:pause()
    else
        AM._wasMusicPlaying = false
    end
end

function AM.resumeAll()
    if AM._wasMusicPlaying and AM._music and AM.musicEnabled then
        AM._music:play()
    end
    AM._wasMusicPlaying = false
end

-- ── toggle helpers ────────────────────────────────────────────────────────────

function AM.setMusic(enabled)
    AM.musicEnabled = enabled
    AM.save()
    if enabled then
        AM.playMusic()
    else
        AM.stopMusic()
    end
end

function AM.setSFX(enabled)
    AM.sfxEnabled = enabled
    AM.save()
end

return AM
