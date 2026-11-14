local t = require("test.t")
local crypto = require("lib.crypto")
local ext = require("lib.extproto")
local gate = require("roles.incoming.gate")
if not crypto.ready() then crypto.init(("gate-test-seed"):rep(4)) end

local T = {}

local function world(cfg)
  local w = { now = 1700000000000, forwarded = {}, lookups = 0 }
  w.inSk, w.inPk = crypto.kxKeypair()
  w.records = {}
  function w.device(id, kind)
    local d = ext.newIdentity(crypto)
    d.id, d.inPk, d.outPk = id, w.inPk, w.inPk
    w.records[id] = { id = id, kind = kind or "pocket", signPk = d.signPk, kxPk = d.kxPk, revoked = 0 }
    return d
  end
  w.G = gate.new({
    crypto = crypto, inSk = w.inSk, inPk = w.inPk, clock = function() return w.now end,
    cfg = cfg or { frameMax = 8192, clockSkewSecs = 120, rate = { burst = 5, perMinute = 60 },
      workerRate = { burst = 20, perMinute = 600 } },
    lookup = function(id)
      w.lookups = w.lookups + 1
      local r = w.records[id]
      if not r then return nil end
      local copy = {} -- like a real network answer: a snapshot, not a live reference
      for k, v in pairs(r) do copy[k] = v end
      return copy
    end,
    forward = function(req) w.forwarded[#w.forwarded + 1] = req end,
  })
  local seq = 0
  function w.frame(dev, msg, counter)
    seq = seq + 1
    return ext.sealRequest(crypto, dev, counter or (w.now * 4096 + seq),
      msg or { v = 1, t = "hello", id = seq, ts = w.now, b = { client = "0.3.0", caps = 2 } })
  end
  return w
end

function T.valid_request_is_forwarded_with_its_signature()
  local w = world()
  local dev = w.device(7)
  t.eq(w.G.handle(w.frame(dev)), "ok")
  local req = w.forwarded[1]
  t.eq(req.d, 7)
  t.ok(ext.verifyRequest(crypto, w.records[7], req.c, req.m, req.s))
  t.eq(w.G.stats.ok, 1)
end

function T.drops_are_counted_by_reason()
  local w = world()
  local dev = w.device(7)
  t.eq(w.G.handle(("x"):rep(9000)), "too_big")
  t.eq(w.G.handle("garbage"), "bad_frame")
  t.eq(w.G.handle(12345), "bad_frame")
  local stranger = ext.newIdentity(crypto); stranger.id, stranger.inPk = 99, w.inPk
  t.eq(w.G.handle(w.frame(stranger)), "unknown_device")
  w.records[7].revoked = 1
  t.eq(w.G.handle(w.frame(dev)), "revoked")
  t.eq(#w.forwarded, 0)
  t.eq(w.G.stats.too_big, 1); t.eq(w.G.stats.bad_frame, 2)
  t.eq(w.G.stats.unknown_device, 1); t.eq(w.G.stats.revoked, 1)
end

function T.replay_and_stale_frames_are_dropped()
  local w = world()
  local dev = w.device(7)
  local f1, f2 = w.frame(dev), w.frame(dev)
  t.eq(w.G.handle(f2), "ok")
  t.eq(w.G.handle(f2), "replay")
  t.eq(w.G.handle(f1), "replay")
  local old = w.frame(dev)
  w.now = w.now + 5 * 60 * 1000
  t.eq(w.G.handle(old), "stale")
  -- timestamp inside the message must also be current
  t.eq(w.G.handle(w.frame(dev, { v = 1, t = "hello", id = 1, ts = w.now - 10 * 60 * 1000,
    b = { client = "x", caps = 0 } })), "stale")
end

function T.messages_that_break_the_schema_never_get_inside()
  local w = world()
  local dev = w.device(7)
  for _, msg in ipairs({
    { v = 1, t = "job.nope", id = 1, ts = w.now, b = {} },
    { v = 1, t = "hello", id = 1, ts = w.now, b = { client = "x", caps = 2, run = "os.shutdown()" } },
    { v = 2, t = "hello", id = 1, ts = w.now, b = { client = "x", caps = 2 } },
    { 1, 2, 3 },
  }) do
    t.eq(w.G.handle(w.frame(dev, msg)), "bad_request")
  end
  t.eq(#w.forwarded, 0)
end

function T.pockets_cannot_send_worker_messages_and_vice_versa()
  local w = world()
  local pocket, turtle = w.device(7, "pocket"), w.device(8, "worker")
  local claim = { v = 1, t = "w.claim", id = 1, ts = w.now, b = { fuel = 10, slots = 16 } }
  local list = { v = 1, t = "job.list", id = 1, ts = w.now, b = { page = 0 } }
  t.eq(w.G.handle(w.frame(pocket, claim)), "not_allowed")
  t.eq(w.G.handle(w.frame(turtle, claim)), "ok")
  t.eq(w.G.handle(w.frame(turtle, list)), "not_allowed")
  t.eq(w.G.handle(w.frame(pocket, list)), "ok")
  -- both kinds may say hello and change their keys
  t.eq(w.G.handle(w.frame(turtle)), "ok")
end

function T.per_device_rate_limit()
  local w = world()
  local a, b = w.device(7), w.device(8)
  for _ = 1, 5 do t.eq(w.G.handle(w.frame(a)), "ok") end
  t.eq(w.G.handle(w.frame(a)), "rate_limited")
  t.eq(w.G.handle(w.frame(b)), "ok", "one device flooding must not block another")
  w.now = w.now + 1000
  t.eq(w.G.handle(w.frame(a)), "ok")
end

function T.workers_get_a_bigger_allowance()
  local w = world()
  local turtle = w.device(8, "worker")
  for _ = 1, 20 do t.eq(w.G.handle(w.frame(turtle)), "ok") end
  t.eq(w.G.handle(w.frame(turtle)), "rate_limited")
end

function T.unknown_devices_cannot_cause_endless_lookups()
  local w = world()
  for i = 1, 200 do
    local s = ext.newIdentity(crypto); s.id, s.inPk = 1000 + (i % 3), w.inPk
    w.G.handle(w.frame(s))
  end
  t.ok(w.lookups <= 40, "lookups: " .. w.lookups)
end

function T.device_records_are_cached_and_can_be_dropped()
  local w = world({ frameMax = 8192, clockSkewSecs = 120, rate = { burst = 100, perMinute = 6000 },
    workerRate = { burst = 100, perMinute = 6000 } })
  local dev = w.device(7)
  for _ = 1, 10 do w.G.handle(w.frame(dev)) end
  t.eq(w.lookups, 1)
  w.records[7].revoked = 1
  t.eq(w.G.handle(w.frame(dev)), "ok") -- still cached
  w.G.drop(7)                           -- COMPUTE says: this device changed
  t.eq(w.G.handle(w.frame(dev)), "revoked")
  -- the cache also expires by itself
  w.records[7].revoked = 0
  w.G.drop(7); w.G.handle(w.frame(dev))
  w.records[7].revoked = 1
  w.now = w.now + 61000
  t.eq(w.G.handle(w.frame(dev)), "revoked")
end

function T.queue_is_bounded()
  local w = world()
  local dev = w.device(7)
  for _ = 1, 200 do w.G.enqueue(w.frame(dev)) end
  t.ok(w.G.queued() <= 64)
  w.G.enqueue(("x"):rep(9000))
  t.eq(w.G.stats.too_big, 1)
  local n = 0
  while w.G.processOne() do n = n + 1 end
  t.ok(n <= 64 and n > 0)
  t.eq(w.G.queued(), 0)
end

function T.random_garbage_never_throws()
  local w = world()
  local seed = 5
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
  for _ = 1, 300 do
    local bytes = {}
    for i = 1, rnd(80) do bytes[i] = string.char(rnd(256)) end
    local ok = pcall(w.G.handle, table.concat(bytes))
    t.ok(ok)
  end
end

return T
