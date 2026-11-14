local t = require("test.t")
local simlib = require("test.sim")
local crypto = require("lib.crypto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
if not crypto.ready() then crypto.init(("rpc-test-seed"):rep(4)) end

local T = {}
local KEY = ("r"):rep(32)

local function mk(sim, name, role, peer)
  local node = sim.node(name)
  local b = bus.new({ modem = node.modem, channel = 4210, role = role, instance = 1,
    keys = { [peer] = KEY }, crypto = crypto, clock = node.clock })
  local r = rpc.new({ bus = b, pull = node.pull, startTimer = node.startTimer,
    queueEvent = node.queueEvent, clock = node.clock })
  node.spawn(r.pumpLoop)
  return node, r
end

local srv = {} -- srv.node is the current test's server node (handlers are built before it exists)

local function pair(handlers)
  local sim = simlib.new()
  local cn, client = mk(sim, "c", "compute", "storage")
  local sn, server = mk(sim, "s", "storage", "compute")
  srv.node = sn
  if handlers then sn.spawn(function() server.serveLoop(handlers) end) end
  return sim, cn, client, sn, server
end

-- run fn on the client node and return what it returned
local function on(sim, node, fn)
  local out
  node.spawn(function() out = { fn() } end)
  t.ok(sim.run(function() return out ~= nil end), "simulation went idle before the call finished")
  return table.unpack(out)
end

function T.call_and_reply()
  local sim, cn, client = pair({ echo = function(body, src, instance)
    return { got = body.x, from = src, inst = instance }
  end })
  local res, err = on(sim, cn, function() return client.call("storage", "echo", { x = 5 }) end)
  t.eq(err, nil)
  t.eq(res, { got = 5, from = "compute", inst = 1 })
end

function T.error_codes_come_back()
  local sim, cn, client = pair({ fail = function() return nil, "not_found" end })
  local res, err = on(sim, cn, function() return client.call("storage", "fail", {}) end)
  t.eq(res, nil); t.eq(err, "not_found")
end

function T.unknown_method()
  local sim, cn, client = pair({})
  local _, err = on(sim, cn, function() return client.call("storage", "nope", {}) end)
  t.eq(err, "no_method")
end

function T.handler_crash_becomes_internal_and_server_survives()
  local sim, cn, client = pair({ boom = function() error("kaboom") end, ok = function() return {} end })
  local _, err = on(sim, cn, function() return client.call("storage", "boom", {}) end)
  t.eq(err, "internal")
  t.eq(on(sim, cn, function() return client.call("storage", "ok", {}) end), {})
end

function T.timeout_when_nobody_answers()
  local sim, cn, client = pair(nil)
  local before = sim.clock()
  local res, err = on(sim, cn, function() return client.call("storage", "echo", {}, 3) end)
  t.eq(res, nil); t.eq(err, "timeout")
  t.eq(sim.clock() - before, 3000)
end

function T.unknown_destination()
  local sim, cn, client = pair({})
  local _, err = on(sim, cn, function() return client.call("monitor", "x", {}) end)
  t.eq(err, "no_key")
end

function T.two_concurrent_calls_get_their_own_replies()
  local sim, cn, client, sn = pair({ slow = function(body)
    if body.wait then srv.node.sleep(body.wait) end
    return { n = body.n }
  end })
  local a, b
  cn.spawn(function() a = client.call("storage", "slow", { n = 1, wait = 2 }) end)
  cn.spawn(function() b = client.call("storage", "slow", { n = 2 }) end)
  sim.run(function() return a and b end)
  t.eq(a, { n = 1 }); t.eq(b, { n = 2 })
end

function T.requests_arriving_during_a_slow_handler_are_not_lost()
  local order = {}
  local sim, cn, client, sn = pair({ work = function(body)
    srv.node.sleep(1)
    order[#order + 1] = body.n
    return {}
  end })
  local done = 0
  for n = 1, 3 do cn.spawn(function() client.call("storage", "work", { n = n }, 10); done = done + 1 end) end
  t.ok(sim.run(function() return done == 3 end))
  t.eq(order, { 1, 2, 3 })
end

function T.notify_reaches_handler_without_reply()
  local got
  local sim, cn, client = pair({ hb = function(body) got = body.id end })
  cn.spawn(function() client.notify("storage", "hb", { id = 7 }) end)
  sim.run(function() return got ~= nil end)
  t.eq(got, 7)
  sim.run(nil, 50)
  t.eq(sim.net.pending("c"), 0)
end

function T.late_reply_to_an_old_call_is_ignored()
  local sim, cn, client, sn = pair({ slow = function(body) srv.node.sleep(body.wait); return { n = body.n } end })
  local first, second
  cn.spawn(function()
    first = { client.call("storage", "slow", { n = 1, wait = 5 }, 1) }
    second = { client.call("storage", "slow", { n = 2, wait = 6 }, 20) }
  end)
  sim.run(function() return second ~= nil end)
  t.eq(first[2], "timeout")
  t.eq(second[1], { n = 2 })
end

function T.malformed_requests_are_dropped()
  local sim, cn, client, sn, server = pair({ ok = function() return {} end })
  -- hand-crafted nonsense that passes bus authentication
  cn.spawn(function()
    client.bus.send("storage", { k = "q" })
    client.bus.send("storage", { k = "q", id = "x", m = 5 })
    client.bus.send("storage", { k = "zzz" })
    client.bus.send("storage", { 1, 2, 3 })
  end)
  sim.run(nil, 100)
  t.eq(on(sim, cn, function() return client.call("storage", "ok", {}) end), {})
end

return T
