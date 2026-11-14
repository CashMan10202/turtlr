-- INCOMING gateway config.
return {
  extSide = "top",     -- side the ENDER modem is on (hears players' pockets and turtles)
  busSide = "back",    -- side the normal WIRELESS modem is on (talks to your base computers)
  frameMax = 8192,     -- biggest message accepted, in bytes
  clockSkewSecs = 120, -- how far a message's timestamp may be from server time
  rate = { burst = 5, perMinute = 60 },         -- per pocket
  workerRate = { burst = 20, perMinute = 600 }, -- per turtle (surveys send many messages)
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
