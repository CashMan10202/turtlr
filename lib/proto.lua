-- Protocol v1: channels, limits, and the exact shape of every message.
-- Anything not described here is rejected. See docs/protocol.md (generated from this file).
local S = require("lib.schema")

local proto = {}

proto.VERSION = 1
proto.CH = { IN = 4201, OUT = 4202, ENROLL = 4203, BUS = 4210, TEL = 4211 }

proto.LIMITS = {
  frameDefault = 2048,      -- bytes, normal max frame
  frameMax = 8192,          -- bytes, hard max (uploads, surveys, layers)
  jobsActive = 3,           -- per player
  jobBlocks = 20000,        -- per job
  uploadBytes = 262144,     -- per uploaded file
  schematicQuota = 2097152, -- bytes stored per player
  areaW = 48, areaD = 48, areaH = 64,
  scanRadius = 16,
}

-- Shared pieces ------------------------------------------------------------
local job, ref = S.tok(24), S.tok(24)
local coord = S.int(-64, 64)
local count = S.int(0, 10000000)
local box = S.array(coord, 6) -- x1,y1,z1,x2,y2,z2 relative to the turtle's start

-- Limits a player sets for their turtle. The owner's config caps every one of them.
proto.TURTLE_LIMITS = S.map({}, {
  w = S.int(1, 48, 16),              -- work area width (x), centred on the turtle
  d = S.int(1, 48, 16),              -- work area depth (z)
  up = S.int(0, 64, 16),             -- blocks above the turtle
  down = S.int(0, 64, 4),            -- blocks below the turtle
  take = S.enum({ "none", "marked", "all" }, "marked"), -- which containers it may take from
  mine = S.bool(false),              -- may it mine ores/stone
  mineMax = S.int(0, 4096, 256),     -- most blocks it may mine
  chop = S.bool(false),              -- may it cut trees
  machines = S.bool(false),          -- may it use machines it finds
  me = S.bool(false),                -- may it attach to an ME network
  fuelReserve = S.int(0, 20000, 500),-- stop and ask when fuel drops below this
  maxMinutes = S.int(1, 1440, 240),  -- give up after this long
  keepOut = S.array(box, 8),         -- boxes it must never enter
})

local shape = S.map({
  kind = S.enum({ "box", "walls", "floor", "cylinder", "tube", "sphere", "dome", "pyramid" }),
  w = S.int(1, 64), h = S.int(1, 64), d = S.int(1, 64),
  block = S.id(),
}, { hollow = S.bool() })

local itemCount = S.map({ id = S.id(), n = count })
local jobState = S.enum({ "quoted", "awaiting_turtle", "survey", "plan", "confirm_plan", "gather", "process",
  "stockpile", "build", "done", "failed", "cancelled" })
local stage = S.enum({ "survey", "gather", "process", "stockpile", "build", "idle" })

-- One step the turtle runs. Fields beyond seq/op depend on the op.
local opSpec = S.map({
  seq = S.int(1, 2147483647),
  op = S.enum({ "goto", "scan", "inspect_inv", "pull", "push", "dig_at", "place_at", "craft", "smelt_start",
    "smelt_collect", "machine_put", "machine_take", "equip", "refuel", "wait", "me_attach", "me_take" }),
}, {
  x = coord, y = coord, z = coord,
  id = S.id(), n = S.int(1, 4096), slot = S.int(1, 16),
  side = S.enum({ "front", "top", "bottom" }),
  tool = S.enum({ "pick", "craft", "scan" }),
  grid = S.array(S.int(0, 16), 9), -- crafting grid: inventory slot per cell, 0 = empty
  r = S.int(1, 24), secs = S.int(1, 600),
})

-- Requests -----------------------------------------------------------------
proto.requests = {
  -- pocket
  ["hello"] = S.map({ client = S.str(16), caps = S.int(0, 7) }),
  ["shape.preview"] = S.map({ shape = shape }),
  ["job.quote"] = S.map({ src = S.enum({ "shape", "lib", "import" }) }, { shape = shape, ref = ref }),
  ["job.confirm"] = S.map({ job = job, quote = S.tok(24) }),
  ["job.cancel"] = S.map({ job = job }),
  ["job.list"] = S.map({ page = S.int(0, 100) }),
  ["job.status"] = S.map({ job = job }),
  ["job.area"] = S.map({ job = job, limits = proto.TURTLE_LIMITS }),
  ["job.plan"] = S.map({ job = job, page = S.int(0, 500) }),
  ["job.approve"] = S.map({ job = job, plan = S.tok(24) }),
  ["lib.list"] = S.map({ page = S.int(0, 500) }),
  ["lib.get_thumb"] = S.map({ ref = ref }),
  ["acct.get"] = S.map({}),
  ["upload.begin"] = S.map({ name = S.str(48, "^[A-Za-z0-9_. -]+$"), size = S.int(1, 262144), sha = S.hex(64),
    chunks = S.int(1, 1024) }),
  ["upload.chunk"] = S.map({ up = S.tok(24), seq = S.int(0, 1023), data = S.bytes(1024), sum = S.hex(16) }),
  ["upload.end"] = S.map({ up = S.tok(24) }),
  ["import.link"] = S.map({ url = S.str(256, "^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%%?&=+-]*$") }),
  ["import.status"] = S.map({ ref = ref }),
  ["rekey"] = S.map({ sign = S.bytes(32), kx = S.bytes(32) }),
  -- worker turtle
  ["w.claim"] = S.map({ fuel = S.int(0, 10000000), slots = S.int(0, 16) }),
  -- pts: each int packs a block: (((x+64)*129 + (y+64))*129 + (z+64))*256 + (index into pal - 1)
  ["w.survey"] = S.map({ job = job, seq = S.int(0, 100000), last = S.bool(), pal = S.array(S.id(), 128),
    pts = S.array(S.int(0, 549552383), 1200) }),
  ["w.inv"] = S.map({ job = job, x = coord, y = coord, z = coord, kind = S.id(),
    items = S.array(itemCount, 128) }),
  ["w.ops"] = S.map({ job = job, after = S.int(0, 2147483647) }),
  ["w.result"] = S.map({ job = job, seq = S.int(1, 2147483647), ok = S.bool() },
    { code = S.enum({ "blocked", "missing", "full", "no_fuel", "no_tool", "out_of_area", "bad_op" }), n = count }),
  ["w.layer"] = S.map({ job = job, y = S.int(0, 255), part = S.int(0, 255) }),
  ["w.progress"] = S.map({ job = job, stage = stage, placed = count, fuel = S.int(0, 10000000),
    x = coord, y = coord, z = coord }),
  ["w.fault"] = S.map({ job = job, code = S.enum({ "blocked", "lost", "no_fuel", "missing", "full", "no_tool",
    "out_of_area", "protected" }), x = coord, y = coord, z = coord }, { id = S.id() }),
  ["w.done"] = S.map({ job = job, placed = count }),
}

-- Rules a plain field list cannot express.
local extra = {
  ["job.quote"] = function(b)
    if b.src == "shape" then
      if not b.shape or b.ref then return "b: src=shape needs shape and no ref" end
    elseif not b.ref or b.shape then
      return "b: src=" .. b.src .. " needs ref and no shape"
    end
  end,
}

-- Responses ----------------------------------------------------------------
local mats = S.array(itemCount, 64)
local dim = S.int(1, 64)

proto.responses = {
  -- unlock = true tells a locked device its owner has released it (it then drops to a normal prompt)
  ["hello"] = S.map({ server = S.str(16), minClient = S.str(16), time = S.int(0, 2 ^ 53),
    state = S.enum({ "ok", "maintenance" }) }, { unlock = S.bool() }),
  ["shape.preview"] = S.map({ w = dim, h = dim, d = dim, count = count, mats = mats }),
  ["job.quote"] = S.map({ quote = S.tok(24), count = count, mats = mats, raw = mats, hand = count,
    eta = S.int(0, 10000000), queue = S.int(0, 10000), turtles = S.int(1, 8), expires = S.int(0, 2 ^ 53) }),
  ["job.confirm"] = S.map({ job = job, state = jobState }),
  ["job.cancel"] = S.map({ job = job, state = jobState }),
  ["job.list"] = S.map({ jobs = S.array(S.map({ job = job, state = jobState, pct = S.int(0, 100),
    name = S.str(32) }), 10), more = S.bool() }),
  ["job.status"] = S.map({ job = job, state = jobState, pct = S.int(0, 100), eta = S.int(0, 10000000),
    placed = count, total = count, queue = S.int(0, 10000), need = S.array(itemCount, 32) }),
  ["job.area"] = S.map({ job = job, limits = proto.TURTLE_LIMITS }),
  ["job.plan"] = S.map({ job = job, plan = S.tok(24), page = S.int(0, 500), more = S.bool(),
    steps = S.array(S.map({ k = S.enum({ "take", "mine", "chop", "craft", "smelt", "machine", "supply" }),
      id = S.id(), n = count }, { x = coord, y = coord, z = coord }), 24) }),
  ["job.approve"] = S.map({ job = job, state = jobState }),
  ["lib.list"] = S.map({ items = S.array(S.map({ ref = ref, name = S.str(32), w = dim, h = dim, d = dim,
    count = count, tested = S.bool() }), 8), more = S.bool() }),
  ["lib.get_thumb"] = S.map({ ref = ref, w = S.int(1, 32), h = S.int(1, 32), data = S.bytes(1024) }),
  ["acct.get"] = S.map({ name = S.str(16), jobsActive = S.int(0, 100), jobsMax = S.int(0, 100),
    blocksMax = count, quotaUsed = S.int(0, 2 ^ 31), quotaMax = S.int(0, 2 ^ 31), devices = S.int(0, 100) }),
  ["upload.begin"] = S.map({ up = S.tok(24), next = S.int(0, 1024) }),
  ["upload.chunk"] = S.map({ up = S.tok(24), next = S.int(0, 1024) }),
  ["upload.end"] = S.map({ ref = ref }),
  ["import.link"] = S.map({ ref = ref }),
  ["import.status"] = S.map({ ref = ref, state = S.enum({ "queued", "fetching", "parsing", "ok", "rejected" }) },
    { code = S.enum({ "too_big", "bad_format", "bad_host", "timeout", "blocked_blocks", "quota" }),
      w = dim, h = dim, d = dim, count = count, dropped = count, hand = count }),
  ["rekey"] = S.map({}),
  ["w.claim"] = S.map({ job = job, stage = stage, limits = proto.TURTLE_LIMITS, scan = S.int(1, 24) }),
  ["w.survey"] = S.map({ next = S.int(0, 100001) }),
  ["w.inv"] = S.map({}),
  ["w.ops"] = S.map({ ops = S.array(opSpec, 32), done = S.bool(), limits = proto.TURTLE_LIMITS }),
  ["w.result"] = S.map({}),
  -- cells: each int packs (x*64 + z)*256 + (index into pal - 1), x and z relative to the layer origin
  ["w.layer"] = S.map({ y = S.int(0, 255), part = S.int(0, 255), more = S.bool(), pal = S.array(S.id(), 128),
    cells = S.array(S.int(0, 1048575), 1200) }),
  ["w.progress"] = S.map({ stop = S.bool() }),
  ["w.fault"] = S.map({ act = S.enum({ "wait", "retry", "abort" }) }),
  ["w.done"] = S.map({}),
}

proto.ERRORS = { "bad_request", "not_found", "not_allowed", "rate_limited", "quota", "busy", "maintenance",
  "too_big", "expired", "internal" }

local reqEnvelope = S.map({ v = S.int(1, 1), t = S.str(24), id = S.int(0, 2147483647), ts = S.int(0, 2 ^ 53) },
  { b = S.map({}) })
local resEnvelope = S.map({ v = S.int(1, 1), t = S.str(24), re = S.int(0, 2147483647), ok = S.bool() },
  { err = S.enum(proto.ERRORS) })

local function envelope(env, msg, bodies)
  if type(msg) ~= "table" then return nil, "message is not a table" end
  local body = msg.b
  msg.b = nil
  local ok, err = S.check(env, msg)
  msg.b = body
  if not ok then return nil, err end
  local spec = bodies[msg.t]
  if not spec then return nil, "t: unknown message type" end
  return spec, body
end

-- Check a request {v, t, id, ts, b}. Returns true, or nil plus a reason.
function proto.validate(msg)
  local spec, body = envelope(reqEnvelope, msg, proto.requests)
  if not spec then return nil, body end
  local ok, err = S.check(spec, body)
  if not ok then return nil, "b." .. err end
  if extra[msg.t] then
    err = extra[msg.t](body)
    if err then return nil, err end
  end
  return true
end

-- Check a response {v, t, re, ok, b} or {v, t, re, ok=false, err}.
function proto.validateResponse(msg)
  local spec, body = envelope(resEnvelope, msg, proto.responses)
  if not spec then return nil, body end
  if msg.ok then
    if msg.err then return nil, "err: not allowed when ok" end
    local ok, err = S.check(spec, body)
    if not ok then return nil, "b." .. err end
  elseif not msg.err or body ~= nil then
    return nil, "a failed response needs err and no body"
  end
  return true
end

return proto
