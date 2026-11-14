-- INCOMING gateway logic. Every frame from a player's device passes through handle().
-- Order of checks (cheapest first, nothing expensive for strangers):
--   size -> frame shape -> rate limit -> device known and not revoked -> decrypt/authenticate
--   -> replay and clock checks -> message matches the schema -> message type allowed for this device
-- Only then is the request forwarded inward, together with the device's signature.
local ext = require("lib.extproto")
local proto = require("lib.proto")
local codec = require("lib.codec")
local ratelimit = require("lib.ratelimit")

local gate = {}

local QUEUE_MAX = 64
local CACHE_MS, MISS_MS = 60000, 10000
local SEQ = 4096

-- message types either kind of device may send
local SHARED = { hello = true, rekey = true }

function gate.new(opts)
  local crypto, cfg, clock = opts.crypto, opts.cfg, opts.clock
  local skewMs = cfg.clockSkewSecs * 1000
  local pocketRate = ratelimit.new({ burst = cfg.rate.burst, perMinute = cfg.rate.perMinute, clock = clock })
  local workerRate = ratelimit.new({ burst = cfg.workerRate.burst, perMinute = cfg.workerRate.perMinute, clock = clock })
  local strangerRate = ratelimit.new({ burst = 10, perMinute = 60, clock = clock })
  local cache = {}     -- devId -> { record = ..., at = ms }  (record false = known to be unknown)
  local lastSeen = {}  -- devId -> highest counter accepted
  local queue = {}
  local G = { stats = {} }

  local function count(reason)
    G.stats[reason] = (G.stats[reason] or 0) + 1
    return reason
  end

  local function lookup(id)
    local now = clock()
    local c = cache[id]
    if c and now - c.at < (c.record and CACHE_MS or MISS_MS) then return c.record or nil end
    -- asking inside costs time: strangers only get a few lookups
    if not (c and c.record) and not strangerRate.allow("lookup") then return nil end
    local record = opts.lookup(id)
    cache[id] = { record = record or false, at = now }
    return record
  end

  -- COMPUTE calls this when a device was revoked, re-keyed or removed.
  function G.drop(id) cache[id] = nil end

  -- Check one frame. Returns "ok" or the reason it was dropped.
  function G.handle(frame)
    if type(frame) ~= "string" then return count("bad_frame") end
    if #frame > cfg.frameMax then return count("too_big") end
    local outer = codec.decode(frame, { maxItems = 8 })
    if type(outer) ~= "table" or type(outer.d) ~= "number" then return count("bad_frame") end

    local got, reason = ext.openRequest(crypto, frame, function(id)
      local record = lookup(id)
      if record then
        local rl = record.kind == "worker" and workerRate or pocketRate
        if not rl.allow(id) then return { limited = true, kxPk = record.kxPk, revoked = record.revoked } end
      end
      return record
    end, opts.inSk, opts.inPk)
    if not got then return count(reason) end
    if got.record.limited then return count("rate_limited") end

    if got.counter <= (lastSeen[got.dev] or 0) then return count("replay") end
    local now = clock()
    local age = now - math.floor(got.counter / SEQ)
    if age > skewMs or age < -skewMs then return count("stale") end
    lastSeen[got.dev] = got.counter

    local msg = got.msg
    if not proto.validate(msg) then return count("bad_request") end
    if msg.ts - now > skewMs or now - msg.ts > skewMs then return count("stale") end
    local workerType = msg.t:sub(1, 2) == "w."
    if not SHARED[msg.t] and workerType ~= (got.record.kind == "worker") then return count("not_allowed") end

    opts.forward({ d = got.dev, c = got.counter, m = got.raw, s = got.sig })
    return count("ok")
  end

  -- Frames arrive faster than they can be checked; keep a short queue and drop the rest.
  function G.enqueue(frame)
    if type(frame) ~= "string" then return count("bad_frame") end
    if #frame > cfg.frameMax then return count("too_big") end
    if #queue >= QUEUE_MAX then return count("queue_full") end
    queue[#queue + 1] = frame
  end

  function G.queued() return #queue end

  -- Handle one queued frame. Returns false when the queue is empty.
  function G.processOne()
    local frame = table.remove(queue, 1)
    if not frame then return false end
    G.handle(frame)
    return true
  end

  return G
end

return gate
