-- MONITOR room config.
return {
  pinRequired = true, -- ask for the admin PIN before dangerous actions
  alarmSide = "none", -- redstone side to power on an alarm: "none", "top", "bottom", "left", "right", "front", "back"
  speaker = true,     -- play alarm sounds if a speaker is attached
  refreshMs = 500,    -- screen refresh time
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
