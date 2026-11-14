-- What each role's config.lua may contain, with ranges and defaults.
local S = require("lib.schema")
local proto = require("lib.proto")

local function def(spec, default) spec.default = default; return spec end

local function logSpec()
  return S.map({}, {
    level = S.enum({ "debug", "info", "warn", "error" }, "info"),
    keepKB = S.int(8, 512, 64),
  })
end

local function rate(burst, perMinute)
  return S.map({}, { burst = S.int(1, 1000, burst), perMinute = S.int(1, 100000, perMinute) })
end

local function common(extra)
  extra.log = logSpec()
  extra.heartbeatSecs = S.int(1, 60, 5)
  return S.map({}, extra)
end

local worldBox = S.array(S.int(-30000000, 30000000), 6)

local specs = {}

specs.storage = common({
  id = S.int(1, 16, 1),
  replicas = S.int(1, 4, 2),
  shardBytes = S.int(1024, 900000, 40000), -- values above 45000 are treated as 45000
  deviceMaxBytes = S.int(65536, 16000000, 1000000),
  scrubMinutes = S.int(1, 1440, 30),
})

specs.compute = common({
  limits = S.map({}, {
    jobsActive = S.int(1, 100, proto.LIMITS.jobsActive),
    jobBlocks = S.int(1, 1000000, proto.LIMITS.jobBlocks),
    uploadBytes = S.int(1024, 262144, proto.LIMITS.uploadBytes),
    schematicQuota = S.int(1024, 2 ^ 31, proto.LIMITS.schematicQuota),
  }),
  turtleMax = proto.TURTLE_LIMITS,
  noBuild = S.array(worldBox, 64),
  priorities = S.array(S.map({ player = S.str(16), weight = S.int(1, 10) }), 64),
  replaceable = S.array(S.id(), 128),
  marker = def(S.id(), "minecraft:lime_wool"),
  level4 = S.bool(false),
  quoteMinutes = S.int(1, 1440, 15),
})

local side = function(default)
  return S.enum({ "top", "bottom", "left", "right", "front", "back" }, default)
end

specs.incoming = common({
  extSide = side("top"),  -- side with the ENDER modem (talks to players' devices)
  busSide = side("back"), -- side with the normal wireless modem (talks to the base)
  frameMax = S.int(512, 8192, proto.LIMITS.frameMax),
  clockSkewSecs = S.int(5, 600, 120),
  rate = rate(5, 60),
  workerRate = rate(20, 600),
})

specs.outgoing = common({
  extSide = side("top"),
  busSide = side("back"),
  frameMax = S.int(512, 8192, proto.LIMITS.frameMax),
  queueMax = S.int(8, 4096, 256),
})

specs.register = common({
  owner = def(S.str(16), "CHANGE_ME"),
  detectRange = S.int(1, 16, 3),
})

specs.ingest = common({
  allowHosts = S.array(S.str(64, "^[a-z0-9.-]+$"), 32),
  maxBytes = S.int(1024, 262144, 262144),
  maxInflated = S.int(1024, 16777216, 4194304),
  maxDim = S.int(1, 64, 64),
  timeoutSecs = S.int(1, 120, 20),
  maxRedirects = S.int(0, 5, 2),
})

specs.monitor = common({
  pinRequired = S.bool(true),
  alarmSide = S.enum({ "none", "top", "bottom", "left", "right", "front", "back" }, "none"),
  speaker = S.bool(true),
  refreshMs = S.int(100, 5000, 500),
})

specs.worker = common({
  scanRadius = S.int(1, 24, proto.LIMITS.scanRadius),
  statusSecs = S.int(1, 60, 5),
})

specs.pocket = common({
  theme = S.enum({ "dark", "light" }, "dark"),
  renderer = S.enum({ "auto", "gfx", "teletext", "text" }, "auto"),
  animations = S.bool(true),
})

specs.gps = S.map({}, {
  set = S.bool(false),
  x = S.int(-30000000, 30000000, 0),
  y = S.int(-64, 320, 0),
  z = S.int(-30000000, 30000000, 0),
})

return specs
