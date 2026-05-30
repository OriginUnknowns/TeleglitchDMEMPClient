-- Multiplayer mod configuration. Edit these to change connection settings.
-- Reloaded on each game launch.

local config = {
    -- Relay server address. Localhost for testing.
    -- Later: switch to Railway public hostname (e.g., "tmeserver.up.railway.app").
    host = "127.0.0.1",
    port = 9999,

    -- Player display name. Leave empty/nil to auto-detect (Steam persona, then Windows username).
    -- Set a string here to force-override (e.g., name_override = "Kito",)
    name_override = nil,

    -- Tickrate for sending state to server (Hz). 30 matches the engine; lower = less bandwidth, more lag.
    send_rate_hz = 30,
}

return config
