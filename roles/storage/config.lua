-- STORAGE manager config. Edit values, keep the shape. Bad values stop the program with a clear message.
return {
  -- Which storage manager this is (1, 2, ...). Each one needs a different number.
  id = 1,
  -- How many NBT Storage blocks each piece of data is copied to.
  replicas = 2,
  -- Size of one piece of data. Minecraft cannot store a single text over 65535 bytes in a block,
  -- so anything above 45000 here is treated as 45000.
  shardBytes = 40000,
  -- Size limit of one NBT Storage block (nbtStorageMaxSize in the Advanced Peripherals config, minus headroom).
  deviceMaxBytes = 1000000,
  -- How often (minutes) to re-check stored data for damage.
  scrubMinutes = 30,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
