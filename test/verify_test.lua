local t = require("test.t")
local shim = require("test.cc_shim")
local core = require("install.verify_core")

local T = {}

local function env(flags)
  local e = shim.new()
  return e, { fs = e.fs, peripheral = e.peripheral, os = e.os, flags = flags or {} }
end

local function byId(results)
  local out = {}
  for _, r in ipairs(results) do out[r.id] = r end
  return out
end

-- a fake NBT Storage that behaves like the real one: rejects data over `limit` characters
local function fakeNbt(limit, initial)
  local stored = initial or {}
  return {
    read = function() return stored end,
    writeTable = function(tbl)
      local n = 0
      for _, v in pairs(tbl) do n = n + #tostring(v) end
      if n > limit then return nil, "too large" end
      stored = tbl
      return true
    end,
  }
end

function T.bare_computer_skips_hardware_and_never_throws()
  local _, ev = env()
  local r = byId(core.runAll(ev))
  for _, id in ipairs({ "nbt.type", "nbt.api", "nbt.size", "geo.api", "me.api", "pd.api", "modem", "gps",
    "turtle.equip", "inv.generic" }) do
    t.eq(r[id].status, "SKIP", id .. ": " .. tostring(r[id].detail))
  end
  t.eq(r["http"].status, "FAIL")
  t.eq(r["cc.version"].status, "FAIL")
  t.eq(r["fs.capacity"].status, "PASS")
end

function T.cc_version_parsing()
  local _, ev = env()
  ev._HOST = "ComputerCraft 1.113.1 (Minecraft 1.21.1)"
  t.eq(byId(core.runAll(ev))["cc.version"].status, "PASS")
  ev._HOST = "ComputerCraft 1.100.8 (Minecraft 1.19.2)"
  t.eq(byId(core.runAll(ev))["cc.version"].status, "FAIL")
end

function T.nbt_detected_under_either_type_name()
  for _, ty in ipairs({ "nbtStorage", "nbt_storage" }) do
    local e, ev = env()
    e.attach("nbt_0", ty, fakeNbt(1000))
    local r = byId(core.runAll(ev))
    t.eq(r["nbt.type"].status, "PASS")
    t.ok(r["nbt.type"].detail:find(ty, 1, true))
    t.ok(r["nbt.type"].detail:find("writeTable", 1, true))
    t.eq(r["nbt.api"].status, "PASS")
    t.eq(r["nbt.size"].status, "SKIP") -- needs the --nbt-write flag
  end
end

function T.nbt_with_unknown_methods_fails_and_lists_them()
  local e, ev = env()
  e.attach("nbt_0", "nbtStorage", { foo = function() end })
  local r = byId(core.runAll(ev))
  t.eq(r["nbt.api"].status, "FAIL")
  t.ok(r["nbt.api"].detail:find("foo", 1, true))
end

function T.nbt_size_probe_finds_the_limit_and_cleans_up()
  local e, ev = env({ nbtWrite = true })
  local dev = fakeNbt(1048576)
  e.attach("nbt_0", "nbtStorage", dev)
  local r = byId(core.runAll(ev))
  t.eq(r["nbt.size"].status, "PASS")
  t.ok(r["nbt.size"].detail:find("1048576", 1, true), r["nbt.size"].detail)
  t.eq(dev.read(), {})
end

function T.real_nbt_method_names_pass_and_can_be_measured()
  local fake_nbt = require("test.fake_nbt")
  local e, ev = env({ nbtWrite = true })
  local p = fake_nbt.new({ style = "save", reader = "load", quiet = true, limit = 5000 })
  p.setName, p.getName, p.getConfiguration = function() end, function() end, function() end
  e.attach("nbt_storage_0", "nbt_storage", p)
  local r = byId(core.runAll(ev))
  t.eq(r["nbt.api"].status, "PASS")
  t.ok(r["nbt.api"].detail:find("load + save", 1, true), r["nbt.api"].detail)
  t.eq(r["nbt.size"].status, "PASS")
  -- the fake counts key + value characters: "d" + 4999
  t.ok(r["nbt.size"].detail:find("4999", 1, true), r["nbt.size"].detail)
  t.eq(p.load(), {})
end

function T.nbt_size_probe_handles_devices_that_throw()
  local e, ev = env({ nbtWrite = true })
  local stored = {}
  e.attach("nbt_0", "nbtStorage", {
    read = function() return stored end,
    writeTable = function(tbl)
      if #tbl.d > 5000 then error("NBT too big") end
      stored = tbl
      return true
    end,
  })
  local r = byId(core.runAll(ev))
  t.ok(r["nbt.size"].detail:find("5000", 1, true), r["nbt.size"].detail)
end

function T.nbt_size_probe_refuses_a_device_holding_data()
  local e, ev = env({ nbtWrite = true })
  local dev = fakeNbt(1000, { important = "data" })
  e.attach("nbt_0", "nbtStorage", dev)
  local r = byId(core.runAll(ev))
  t.eq(r["nbt.size"].status, "SKIP")
  t.ok(r["nbt.size"].detail:find("not empty", 1, true))
  t.eq(dev.read(), { important = "data" })
end

function T.a_throwing_peripheral_fails_one_row_only()
  local e, ev = env()
  e.attach("m", "modem", { isWireless = function() error("kaboom") end })
  e.attach("pd", "playerDetector", { getPlayersInRange = function() end, getPlayerPos = function() end })
  local results = core.runAll(ev)
  local r = byId(results)
  t.eq(r["modem"].status, "FAIL")
  t.ok(r["modem"].detail:find("kaboom", 1, true))
  t.eq(r["pd.api"].status, "PASS")
  t.eq(#results, #core.checks)
end

function T.geo_me_and_detector_method_checks()
  local e, ev = env({ scan = true })
  e.setTime(0)
  e.attach("g", "geoScanner", { scan = function(r) return { { name = "minecraft:stone" }, { name = "minecraft:dirt" } } end })
  e.attach("me", "meBridge", { listItems = function() end, craftItem = function() end })
  e.attach("pd", "playerDetector", { getPlayersInRange = function() end })
  local r = byId(core.runAll(ev))
  t.eq(r["geo.api"].status, "PASS")
  t.ok(r["geo.api"].detail:find("2 blocks", 1, true), r["geo.api"].detail)
  t.eq(r["me.api"].status, "PASS")
  t.eq(r["pd.api"].status, "FAIL") -- no position method
end

function T.geo_scan_error_is_reported()
  local e, ev = env({ scan = true })
  e.attach("g", "geoScanner", { scan = function() return nil, "Radius is too big" end })
  local r = byId(core.runAll(ev))
  t.eq(r["geo.api"].status, "FAIL")
  t.ok(r["geo.api"].detail:find("Radius is too big", 1, true))
end

function T.turtle_and_gps_checks()
  local e, ev = env()
  ev.turtle = { equipLeft = function() end, equipRight = function() end }
  ev.gps = { locate = function() return 10, 64, -20 end }
  e.attach("front", "minecraft:chest", { list = function() return { {}, {} } end })
  local r = byId(core.runAll(ev))
  t.eq(r["turtle.equip"].status, "PASS")
  t.eq(r["gps"].status, "PASS")
  t.ok(r["gps"].detail:find("10", 1, true))
  t.eq(r["inv.generic"].status, "PASS")
  ev.gps = { locate = function() return nil end }
  t.eq(byId(core.runAll(ev))["gps"].status, "FAIL")
end

function T.graphics_mode_is_always_restored()
  local _, ev = env({ gfx = true })
  local mode = 0
  ev.term = { setGraphicsMode = function(m) mode = m end, setPixel = function() error("draw failed") end }
  local r = byId(core.runAll(ev))
  t.eq(r["gfx"].status, "FAIL")
  t.eq(mode, 0)
end

function T.report_has_one_line_per_check()
  local _, ev = env()
  local lines = core.report(core.runAll(ev))
  t.eq(#lines, #core.checks)
  t.ok(lines[1]:find("^%[%u+%]"))
end

return T
