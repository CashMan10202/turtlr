local t = require("test.t")
local shim = require("test.cc_shim")
local fake_nbt = require("test.fake_nbt")
local device = require("roles.storage.device")
local T = {}

local function methodsOf(p)
  local out = {}
  for k in pairs(p) do out[#out + 1] = k end
  return out
end

function T.round_trip_in_every_write_style()
  for _, style in ipairs({ "writeTable", "writeJson", "save" }) do
    local p = fake_nbt.new({ style = style })
    local d = assert(device.wrap("nbt_0", p, methodsOf(p)))
    local cells = { c1 = "head|1\nQUJD", c2 = 'x"y\\z\n==' }
    t.ok(d.store(cells), style)
    t.eq(d.load(), cells, style)
    t.eq(d.name, "nbt_0")
  end
end

function T.wrap_needs_read_and_a_writer()
  t.eq(device.wrap("x", { read = function() end }, { "read" }), nil)
  t.eq(device.wrap("x", { writeTable = function() end }, { "writeTable" }), nil)
end

function T.over_limit_store_fails_and_keeps_old_content()
  local p = fake_nbt.new({ limit = 100 })
  local d = device.wrap("n", p, methodsOf(p))
  t.ok(d.store({ a = "small" }))
  local ok, err = d.store({ a = ("x"):rep(200) })
  t.eq(ok, nil); t.ok(type(err) == "string")
  t.eq(d.load(), { a = "small" })
  t.eq(d.errors, 1)
end

function T.throwing_peripheral_never_throws_out()
  local p, ctl = fake_nbt.new()
  local d = device.wrap("n", p, methodsOf(p))
  ctl.fail(2)
  local cells, err = d.load()
  t.eq(cells, nil); t.ok(err:find("detached", 1, true))
  t.eq(d.store({ a = "b" }), nil)
  t.eq(d.errors, 2)
  t.ok(d.store({ a = "b" }))
end

function T.non_table_or_mixed_reads_are_cleaned()
  local p, ctl = fake_nbt.new()
  local d = device.wrap("n", p, methodsOf(p))
  ctl.readGarbage = "not a table"
  t.eq(d.load(), {})
  t.eq(d.junk, 1)
  ctl.readGarbage = { good = "yes", num = 5, nested = { 1 }, [7] = "numeric key" }
  t.eq(d.load(), { good = "yes" })
  t.eq(d.junk, 4)
end

function T.discover_finds_both_type_names_sorted()
  local e = shim.new()
  e.attach("nbt_2", "nbtStorage", (fake_nbt.new()))
  e.attach("left", "modem", {})
  e.attach("nbt_1", "nbt_storage", (fake_nbt.new()))
  e.attach("broken", "nbtStorage", { foo = function() end })
  local list = device.discover(e.peripheral)
  t.eq(#list, 2)
  t.eq(list[1].name, "nbt_1"); t.eq(list[2].name, "nbt_2")
end

return T
