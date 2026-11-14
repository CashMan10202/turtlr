local t = require("test.t")
local simlib = require("test.sim")
local H = require("test.engine_helper")
local crypto = require("lib.crypto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local engine = require("roles.storage.engine")
local server = require("roles.storage.server")
local storeclient = require("lib.storeclient")

local T = {}
local KEYS = { cs = ("1"):rep(32), ss = ("2"):rep(32) }

-- a storage manager computer in the simulator, all sharing one rack of devices
local function manager(sim, rack, id)
  local node = sim.node("s" .. id)
  local m = { node = node, id = id }
  function m.start()
    local b = bus.new({ modem = node.modem, channel = 4210, role = "storage", instance = id,
      keys = { compute = KEYS.cs, storage = KEYS.ss }, crypto = crypto, clock = node.clock })
    local r = rpc.new({ bus = b, pull = node.pull, startTimer = node.startTimer,
      queueEvent = node.queueEvent, clock = node.clock })
    local S
    local E = engine.new({ devices = rack.devs, crypto = crypto, replicas = 2, shardBytes = 20000,
      deviceMaxBytes = 400000, clock = node.clock, yield = function() S.beat() end })
    S = server.new({ engine = E, rpc = r, id = id, clock = node.clock })
    m.server, m.engine = S, E
    node.spawn(r.pumpLoop)
    node.spawn(function() S.loop(node.pull, node.startTimer) end)
  end
  m.start()
  return m
end

local function world(nManagers)
  local sim = simlib.new()
  local rack = H.rack(4, 400000)
  local managers = {}
  for id = 1, nManagers do managers[id] = manager(sim, rack, id) end
  local cn = sim.node("compute")
  local b = bus.new({ modem = cn.modem, channel = 4210, role = "compute", instance = 1,
    keys = { storage = KEYS.cs }, crypto = crypto, clock = cn.clock })
  local r = rpc.new({ bus = b, pull = cn.pull, startTimer = cn.startTimer, queueEvent = cn.queueEvent,
    clock = cn.clock })
  cn.spawn(r.pumpLoop)
  local client = storeclient.new({ rpc = r, sleep = cn.sleep })
  local function run(fn)
    local out
    cn.spawn(function() out = { fn() } end)
    t.ok(sim.run(function() return out ~= nil end), "simulation went idle")
    return table.unpack(out)
  end
  return { sim = sim, rack = rack, managers = managers, client = client, run = run, cn = cn, rpc = r }
end

function T.small_values_round_trip()
  local w = world(1)
  t.ok(w.run(function() return w.client.put("jobs", "j1", "hello") end))
  t.eq(w.run(function() return w.client.get("jobs", "j1") end), "hello")
  t.eq(w.run(function() return w.client.stat("jobs", "j1") end), { size = 5, ver = 1, shards = 1 })
  t.eq({ w.run(function() return w.client.list("jobs") end) }, { { "j1" }, false })
  t.ok(w.run(function() return w.client.delete("jobs", "j1") end))
  t.eq({ w.run(function() return w.client.get("jobs", "j1") end) }, { nil, "not_found" })
end

function T.large_value_goes_in_parts()
  local w = world(1)
  local big = H.blob(100000)
  t.ok(w.run(function() return w.client.put("schematics", "big", big) end))
  t.eq(w.run(function() return w.client.get("schematics", "big") end), big)
  t.eq(w.managers[1].engine.get("schematics", "big"), big)
end

function T.tables_round_trip()
  local w = world(1)
  local job = { id = "J1", state = "queued", mats = { { id = "minecraft:stone", n = 64 } } }
  t.ok(w.run(function() return w.client.putTable("jobs", "J1", job) end))
  t.eq(w.run(function() return w.client.getTable("jobs", "J1") end), job)
  w.run(function() return w.client.put("jobs", "notatable", "\255\255") end)
  t.eq({ w.run(function() return w.client.getTable("jobs", "notatable") end) }, { nil, "corrupt" })
end

function T.errors_pass_through()
  local w = world(1)
  t.eq({ w.run(function() return w.client.put("nope", "k", "v") end) }, { nil, "bad_key" })
  t.eq({ w.run(function() return w.client.get("jobs", "missing") end) }, { nil, "not_found" })
end

function T.lowest_id_is_primary_and_the_other_stays_silent()
  local w = world(2)
  t.ok(w.run(function() return w.client.put("jobs", "a", "1") end))
  t.eq(w.managers[1].server.isPrimary(), true)
  t.eq(w.managers[2].server.isPrimary(), false)
end

function T.standby_takes_over_and_keeps_the_data()
  local w = world(2)
  local big = H.blob(60000)
  w.run(function() return w.client.put("jobs", "a", "kept") end)
  w.run(function() return w.client.put("schematics", "b", big) end)
  w.managers[1].node.kill()
  t.eq(w.run(function() return w.client.get("jobs", "a") end), "kept")
  t.eq(w.managers[2].server.isPrimary(), true)
  t.eq(w.run(function() return w.client.get("schematics", "b") end), big)
  t.ok(w.run(function() return w.client.put("jobs", "c", "after failover") end))
end

function T.returning_lower_id_takes_primary_back_and_sees_new_data()
  local w = world(2)
  w.run(function() return w.client.put("jobs", "a", "v1") end)
  w.managers[1].node.kill()
  w.run(function() return w.client.put("jobs", "a", "v2") end)
  w.managers[1].node.revive()
  w.managers[1].start() -- reboot: fresh program, empty memory
  w.sim.runFor(15000)
  t.eq(w.managers[1].server.isPrimary(), true)
  t.eq(w.managers[2].server.isPrimary(), false)
  t.eq(w.run(function() return w.client.get("jobs", "a") end), "v2")
end

function T.abandoned_upload_is_discarded()
  local w = world(1)
  w.run(function() return w.client.put("jobs", "warm", "up") end)
  local res = w.run(function()
    return w.rpc.call("storage", "put_part", { ns = "jobs", key = "half", up = "U1", i = 1, n = 3, d = "part one" })
  end)
  t.eq(res.done, 0)
  t.eq(w.managers[1].server.uploads(), 1)
  w.sim.runFor(70000)
  t.eq(w.managers[1].server.uploads(), 0)
  t.eq({ w.run(function() return w.client.get("jobs", "half") end) }, { nil, "not_found" })
end

function T.upload_limits()
  local w = world(1)
  w.run(function() return w.client.put("jobs", "warm", "up") end)
  local function part(up, i, n, d)
    return w.run(function()
      return w.rpc.call("storage", "put_part", { ns = "jobs", key = "k", up = up, i = i, n = n, d = d })
    end)
  end
  for u = 1, 4 do t.ok(part("U" .. u, 1, 2, "x")) end
  t.eq({ part("U5", 1, 2, "x") }, { nil, "busy" })
  t.eq({ part("U1", 3, 2, "x") }, { nil, "bad_request" })
  t.eq({ part("U1", 1, 200, "x") }, { nil, "bad_request" })
end

function T.scrub_runs_in_the_background_and_repairs()
  local w = world(1)
  local v = H.blob(30000)
  w.run(function() return w.client.put("jobs", "a", v) end)
  w.rack.ctl[1].wipe(); w.rack.ctl[3].wipe() -- one copy of each shard
  w.sim.runFor(120000)
  local h = w.run(function() return w.client.health() end)
  t.eq(h.degraded, 0); t.eq(h.lost, 0); t.eq(h.devices, 4)
  t.eq(w.run(function() return w.client.get("jobs", "a") end), v)
end

function T.heartbeats_continue_during_a_long_operation()
  -- a standby must not take over while the primary is busy with a big write
  local w = world(2)
  w.run(function() return w.client.put("jobs", "warm", "up") end)
  local became = false
  w.sim.net.tap(function() if w.managers[2].server.isPrimary() then became = true end end)
  t.ok(w.run(function() return w.client.put("schematics", "big", H.blob(300000)) end))
  t.ok(not became)
end

return T
