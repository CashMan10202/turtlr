-- Boots the real roles/storage/main.lua inside a simulated computer and talks to it.
local t = require("test.t")
local simlib = require("test.sim")
local shim = require("test.cc_shim")
local fake_nbt = require("test.fake_nbt")
local crypto = require("lib.crypto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local storeclient = require("lib.storeclient")
local keys_core = require("install.keys_core")
if not crypto.ready() then crypto.init(("main-test-seed"):rep(4)) end

local T = {}

local function slurp(path)
  local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end

local n = 0
local allKeys = keys_core.generate(function(len) n = n + 1; return string.char(n):rep(len) end, keys_core.ROLES)

local function bootStorage(sim, setup)
  local node = sim.node("storage1")
  local e = shim.new()
  e.write("/bs/role/config.lua", "return { id = 1, scrubMinutes = 1 }")
  e.write("/bs/keys.lua", keys_core.serialise(allKeys.storage))
  e.attach("top", "modem", node.modem)
  for i = 1, 3 do e.attach("nbt_" .. i, "nbtStorage", (fake_nbt.new())) end
  if setup then setup(e) end
  local printed = {}
  local env = setmetatable({
    fs = e.fs, peripheral = e.peripheral,
    os = { epoch = node.clock, pullEvent = node.pull, startTimer = node.startTimer, queueEvent = node.queueEvent },
    parallel = { waitForAny = function(...)
      for _, fn in ipairs({ ... }) do node.spawn(fn) end
      node.pull("__forever")
    end },
    print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end,
  }, { __index = _G })
  local chunk = assert(load(slurp("roles/storage/main.lua"), "=main", "t", env))
  local failure
  node.spawn(function()
    local ok, err = pcall(chunk)
    if not ok then failure = err end
  end)
  return e, printed, function() return failure end
end

local function computeClient(sim)
  local cn = sim.node("compute")
  local b = bus.new({ modem = cn.modem, channel = 4210, role = "compute", instance = 1,
    keys = allKeys.compute, crypto = crypto, clock = cn.clock })
  local r = rpc.new({ bus = b, pull = cn.pull, startTimer = cn.startTimer, queueEvent = cn.queueEvent,
    clock = cn.clock })
  cn.spawn(r.pumpLoop)
  local client = storeclient.new({ rpc = r, sleep = cn.sleep })
  return function(fn)
    local out
    cn.spawn(function() out = { fn(client) } end)
    t.ok(sim.run(function() return out ~= nil end), "simulation went idle")
    return table.unpack(out)
  end
end

function T.boots_serves_and_logs()
  local sim = simlib.new()
  local e, printed, failure = bootStorage(sim)
  local run = computeClient(sim)
  t.ok(run(function(c) return c.put("jobs", "J1", "hello from compute") end), tostring(failure()))
  t.eq(run(function(c) return c.get("jobs", "J1") end), "hello from compute")
  t.eq(run(function(c) return c.health() end).devices, 3)
  t.eq(failure(), nil)
  t.ok(printed[1]:find("3 NBT Storage", 1, true))
  t.ok(e.read("/bs/log.txt"):find("started", 1, true))
end

function T.data_survives_a_reboot_of_the_storage_computer()
  local sim = simlib.new()
  local devs = {}
  for i = 1, 3 do devs[i] = (fake_nbt.new()) end
  local function setup(e) for i = 1, 3 do e.attach("nbt_" .. i, "nbtStorage", devs[i]) end end
  bootStorage(sim, setup)
  local run = computeClient(sim)
  run(function(c) return c.put("jobs", "J1", "persisted") end)
  -- a brand new simulation = everything powered off and on again; only the devices keep state
  local sim2 = simlib.new()
  bootStorage(sim2, setup)
  local run2 = computeClient(sim2)
  t.eq(run2(function(c) return c.get("jobs", "J1") end), "persisted")
end

function T.clear_errors_when_setup_is_incomplete()
  for _, case in ipairs({
    { function(e) e.fs.delete("/bs/keys.lua") end, "keys" },
    { function(e) e.write("/bs/role/config.lua", "return { replicas = 99 }") end, "replicas" },
  }) do
    local sim = simlib.new()
    local _, _, failure = bootStorage(sim, case[1])
    sim.run(nil, 50)
    t.ok(tostring(failure()):find(case[2], 1, true), tostring(failure()))
  end
end

return T
