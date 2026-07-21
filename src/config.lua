-- Mus Online Configuration
-- Switch between local development and production server

local config = {}

-- Production is the DEFAULT: a plain `love .` connects to the cloud VPS.
-- Opt into localhost dev only by setting MUS_DEV=true (e.g. when running
-- `love server/` on your machine).
local DEV = os.getenv("MUS_DEV") == "true"

if DEV then
    -- Development: Connect to localhost
    config.SERVER_ADDRESS = "127.0.0.1"
    config.SERVER_PORT = tonumber(os.getenv("MUS_SERVER_PORT")) or 12346
else
    -- Production: Connect to cloud server (default)
    config.SERVER_ADDRESS = os.getenv("MUS_SERVER_IP") or "75.119.142.247"
    config.SERVER_PORT = tonumber(os.getenv("MUS_SERVER_PORT")) or 12346
end

return config
