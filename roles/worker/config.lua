-- WORKER turtle config.
return {
  scanRadius = 16, -- Geo Scanner radius to use (must not exceed the server's scanBlocksMaxCostRadius)
  statusSecs = 5,  -- how often it reports progress
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
