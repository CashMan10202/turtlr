-- OUTGOING gateway config.
return {
  frameMax = 8192, -- biggest message sent, in bytes
  queueMax = 256,  -- most replies waiting to be sent before new ones are dropped
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
