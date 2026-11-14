-- POCKET app config.
return {
  theme = "dark",    -- "dark" or "light"
  renderer = "auto", -- "auto", "gfx" (CC: Graphics), "teletext" or "text"
  animations = true,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
