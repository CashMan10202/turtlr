-- INGEST computer config: the only computer allowed to download schematics.
return {
  -- Exact host names downloads are allowed from. Nothing else is fetched.
  allowHosts = { "cdn.modrinth.com", "raw.githubusercontent.com" },
  maxBytes = 262144,     -- biggest download
  maxInflated = 4194304, -- biggest size after unpacking (stops "zip bombs")
  maxDim = 64,           -- biggest schematic side, in blocks
  timeoutSecs = 20,
  maxRedirects = 2,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
