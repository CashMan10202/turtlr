local t = require("test.t")
local fake_net = require("test.fake_net")
local crypto = require("lib.crypto")
local codec = require("lib.codec")
local bus = require("lib.bus")
if not crypto.ready() then crypto.init(("bus-test-seed"):rep(4)) end

local T = {}
local K = { cs = ("a"):rep(32), ss = ("b"):rep(32), cc = ("c"):rep(32) }

local function setup()
  local net = fake_net.new()
  local now = { 1700000000000 }
  local clock = function() return now[1] end
  local function node(name, role, instance, keys)
    local m = net.modem(name)
    return bus.new({ modem = m, channel = 4210, role = role, instance = instance, keys = keys,
      crypto = crypto, clock = clock })
  end
  local compute = node("c", "compute", 1, { storage = K.cs, compute = K.cc })
  local s1 = node("s1", "storage", 1, { compute = K.cs, storage = K.ss })
  local s2 = node("s2", "storage", 2, { compute = K.cs, storage = K.ss })
  return net, now, compute, s1, s2
end

local function recv(net, name, b)
  local ev = net.next(name)
  if not ev then return nil, "nothing" end
  return b.receive(ev[3], ev[5])
end

function T.round_trip()
  local net, _, compute, s1 = setup()
  t.ok(compute.send("storage", { m = "get", key = "a", n = 5 }))
  local got = assert(recv(net, "s1", s1))
  t.eq(got, { src = "compute", instance = 1, msg = { m = "get", key = "a", n = 5 } })
end

function T.opens_its_channel()
  local net = fake_net.new()
  local m = net.modem("x")
  bus.new({ modem = m, channel = 4210, role = "compute", instance = 1, keys = {}, crypto = crypto,
    clock = function() return 1 end })
  t.ok(m.isOpen(4210))
end

function T.payload_is_not_readable_on_the_wire()
  local net, _, compute = setup()
  local seen
  net.tap(function(_, _, payload) seen = payload end)
  compute.send("storage", { secret = "hunter2hunter2" })
  t.ok(type(seen) == "string" and not seen:find("hunter2", 1, true))
end

function T.frame_for_another_role_is_ignored()
  local net, _, compute, s1 = setup()
  compute.send("compute", { x = 1 })
  local got, why = recv(net, "s1", s1)
  t.eq(got, nil); t.eq(why, "not_for_me")
end

function T.wrong_channel_is_ignored()
  local net, _, compute, s1 = setup()
  compute.send("storage", { x = 1 })
  local ev = net.next("s1")
  local got, why = s1.receive(9999, ev[5])
  t.eq(got, nil); t.eq(why, "not_for_me")
end

function T.unknown_sender_role()
  local net, _, _, s1 = setup()
  local stranger = bus.new({ modem = net.modem("z"), channel = 4210, role = "ingest", instance = 1,
    keys = { storage = ("z"):rep(32) }, crypto = crypto, clock = function() return 1700000000000 end })
  stranger.send("storage", { x = 1 })
  local got, why = recv(net, "s1", s1)
  t.eq(got, nil); t.eq(why, "no_key")
end

function T.wrong_key_fails_authentication()
  local net, _, _, s1 = setup()
  local fake = bus.new({ modem = net.modem("z"), channel = 4210, role = "compute", instance = 9,
    keys = { storage = ("z"):rep(32) }, crypto = crypto, clock = function() return 1700000000000 end })
  fake.send("storage", { x = 1 })
  local got, why = recv(net, "s1", s1)
  t.eq(got, nil); t.eq(why, "bad_auth")
end

function T.any_tampered_byte_is_rejected()
  local net, _, compute, s1 = setup()
  compute.send("storage", { m = "delete", key = "important" })
  local frame = net.next("s1")[5]
  for i = 1, #frame do
    local bad = frame:sub(1, i - 1) .. string.char((frame:byte(i) + 1) % 256) .. frame:sub(i + 1)
    local ok, got = pcall(s1.receive, 4210, bad)
    t.ok(ok, "threw at byte " .. i)
    t.eq(got, nil, "accepted tampered byte " .. i)
  end
  t.ok(s1.receive(4210, frame), "the untouched frame is still fine")
end

function T.replay_and_reorder_are_rejected()
  local net, _, compute, s1 = setup()
  compute.send("storage", { n = 1 })
  compute.send("storage", { n = 2 })
  local f1, f2 = net.next("s1")[5], net.next("s1")[5]
  t.eq(s1.receive(4210, f2).msg.n, 2)
  local got, why = s1.receive(4210, f2)
  t.eq(got, nil); t.eq(why, "replay")
  got, why = s1.receive(4210, f1)
  t.eq(got, nil); t.eq(why, "replay")
end

function T.stale_frames_are_rejected_even_after_receiver_reboot()
  local net, now, compute = setup()
  compute.send("storage", { n = 1 })
  local old = net.next("s1")[5]
  now[1] = now[1] + 10 * 60 * 1000
  -- a freshly booted receiver has no memory of counters; the time check still stops the replay
  local rebooted = bus.new({ modem = net.modem("s1b"), channel = 4210, role = "storage", instance = 1,
    keys = { compute = K.cs }, crypto = crypto, clock = function() return now[1] end })
  local got, why = rebooted.receive(4210, old)
  t.eq(got, nil); t.eq(why, "stale")
end

function T.frames_from_the_future_are_rejected()
  local net, now, compute, s1 = setup()
  now[1] = now[1] + 10 * 60 * 1000
  compute.send("storage", { n = 1 })
  local f = net.next("s1")[5]
  now[1] = now[1] - 10 * 60 * 1000
  local got, why = s1.receive(4210, f)
  t.eq(got, nil); t.eq(why, "stale")
end

function T.instances_of_one_role_are_tracked_separately()
  local net, _, compute, s1, s2 = setup()
  s1.send("compute", { from = 1 }); s2.send("compute", { from = 2 }); s1.send("compute", { from = 11 })
  t.eq(recv(net, "c", compute).instance, 1)
  t.eq(recv(net, "c", compute).instance, 2)
  t.eq(recv(net, "c", compute).msg.from, 11)
end

function T.same_role_peers_use_the_role_key()
  local net, _, _, s1, s2 = setup()
  s1.send("storage", { hb = 1 })
  t.eq(recv(net, "s2", s2).msg.hb, 1)
end

function T.counters_increase_even_when_the_clock_stands_still_or_goes_back()
  local net, now, compute, s1 = setup()
  compute.send("storage", { n = 1 }); compute.send("storage", { n = 2 })
  now[1] = now[1] - 5000
  compute.send("storage", { n = 3 })
  for n = 1, 3 do t.eq(recv(net, "s1", s1).msg.n, n) end
end

function T.send_errors()
  local _, _, compute = setup()
  local ok, why = compute.send("monitor", { x = 1 })
  t.eq(ok, nil); t.eq(why, "no_key")
  ok, why = compute.send("storage", { d = ("x"):rep(70000) })
  t.eq(ok, nil); t.eq(why, "too_big")
  ok, why = compute.send("storage", { f = 1.5 })
  t.eq(ok, nil); t.eq(why, "bad_msg")
end

function T.garbage_never_throws()
  local _, _, _, s1 = setup()
  local seed = 99
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
  for _ = 1, 500 do
    local bytes = {}
    for i = 1, rnd(60) do bytes[i] = string.char(rnd(256)) end
    local ok, got = pcall(s1.receive, 4210, table.concat(bytes))
    t.ok(ok and got == nil)
  end
  for _, junk in ipairs({ 5, true, {}, { s = "compute" }, codec.encode({ s = "compute", i = 1, d = "storage", c = 1 }) }) do
    local ok, got = pcall(s1.receive, 4210, junk)
    t.ok(ok and got == nil)
  end
end

return T
