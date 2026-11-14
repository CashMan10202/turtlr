local t = require("test.t")
local shim = require("test.cc_shim")

local T = {}

function T.deep_equality()
  t.eq({ a = { 1, 2 } }, { a = { 1, 2 } })
  t.err(function() t.eq({ a = 1 }, { a = 2 }) end)
  t.err(function() t.eq({ 1 }, { 1, 2 }) end)
end

function T.fs_round_trip()
  local env = shim.new()
  local h = env.fs.open("/a/b.txt", "w")
  h.write("hello")
  h.close()
  t.ok(env.fs.exists("/a/b.txt"))
  t.ok(env.fs.isDir("/a"))
  local r = env.fs.open("a/b.txt", "r")
  t.eq(r.readAll(), "hello")
  r.close()
  t.eq(env.fs.getSize("/a/b.txt"), 5)
  t.eq(env.fs.list("/a"), { "b.txt" })
  t.eq(env.fs.open("/missing", "r"), nil)
end

function T.fs_append_and_delete()
  local env = shim.new()
  local h = env.fs.open("/x", "w"); h.write("a"); h.close()
  h = env.fs.open("/x", "a"); h.write("b"); h.close()
  h = env.fs.open("/x", "r"); t.eq(h.readAll(), "ab"); h.close()
  env.fs.delete("/x")
  t.ok(not env.fs.exists("/x"))
end

function T.fs_move_onto_existing_errors()
  local env = shim.new()
  for _, p in ipairs({ "/a", "/b" }) do
    local h = env.fs.open(p, "w"); h.write("x"); h.close()
  end
  t.err(function() env.fs.move("/a", "/b") end)
  env.fs.delete("/b")
  env.fs.move("/a", "/b")
  t.ok(env.fs.exists("/b") and not env.fs.exists("/a"))
end

function T.fs_capacity_enforced()
  local env = shim.new()
  env.capacity = 10
  local h = env.fs.open("/big", "w")
  t.err(function() h.write(("x"):rep(11)); h.close() end)
  t.eq(env.fs.getCapacity("/"), 10)
end

function T.peripheral_found_by_type()
  local env = shim.new()
  env.attach("left", "nbtStorage", { read = function() return 7 end })
  t.eq(env.peripheral.getType("left"), "nbtStorage")
  t.eq(env.peripheral.find("nbtStorage").read(), 7)
  t.eq(env.peripheral.find("nope"), nil)
  t.eq(env.peripheral.getMethods("left"), { "read" })
  t.eq(env.peripheral.call("left", "read"), 7)
end

function T.clock_is_settable()
  local env = shim.new()
  env.setTime(1234)
  t.eq(env.os.epoch("utc"), 1234)
end

return T
