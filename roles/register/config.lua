-- REGISTER terminal config.
return {
  -- Your Minecraft name. Only this player can enrol pockets and turtles. CHANGE THIS.
  owner = "CHANGE_ME",
  -- How close (blocks) a player must stand to be registered.
  detectRange = 3,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
