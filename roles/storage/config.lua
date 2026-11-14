-- STORAGE manager config. Edit values, keep the shape. Bad values stop the program with a clear message.
return {
  -- Which storage manager this is (1, 2, ...). Each one needs a different number.
  id = 1,
  -- How many NBT Storage blocks each piece of data is copied to.
  replicas = 2,
  -- Size of one piece of data. Must stay well under the NBT Storage limit.
  shardBytes = 200000,
  -- Size limit of one NBT Storage block (nbtStorageMaxSize in the Advanced Peripherals config, minus headroom).
  deviceMaxBytes = 1000000,
  -- How often (minutes) to re-check stored data for damage.
  scrubMinutes = 30,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
