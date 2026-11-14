local t = require("test.t")
local shim = require("test.cc_shim")
local log = require("lib.log")
local T = {}

local function mk(opts)
  local e = shim.new()
  e.setTime(1000)
  opts = opts or {}
  opts.fs, opts.path, opts.clock = e.fs, "/bs/log.txt", function() return e.os.epoch("utc") end
  return e, log.new(opts)
end

function T.writes_formatted_lines()
  local e, L = mk({ level = "debug" })
  L.info("store", "put ok", { key = "a", n = 3, ok = true })
  t.eq(e.read("/bs/log.txt"), "1000 INFO store put ok key=a n=3 ok=true\n")
end

function T.level_filter()
  local e, L = mk({ level = "warn" })
  L.debug("x", "no"); L.info("x", "no"); L.warn("x", "yes"); L.error("x", "yes")
  t.eq(#L.tail(10), 2)
end

function T.newlines_cannot_forge_lines()
  local e, L = mk()
  L.info("x", "a\nb", { k = "c\r\nd" })
  t.eq(#L.tail(10), 1)
end

function T.rotation_bounds_disk_use()
  local e, L = mk({ keepKB = 8 })
  for i = 1, 2000 do L.info("x", ("m"):rep(50), { i = i }) end
  local a, b = e.read("/bs/log.txt") or "", e.read("/bs/log.txt.1") or ""
  t.ok(#a <= 8192 + 200, "current file too big: " .. #a)
  t.ok(#a + #b <= 2 * 8192 + 400)
  t.ok(#b > 0)
  t.ok(L.tail(1)[1]:find("i=2000", 1, true))
end

function T.tail_returns_last_lines_in_order()
  local e, L = mk()
  for i = 1, 5 do L.info("x", "m" .. i) end
  local lines = L.tail(2)
  t.ok(lines[1]:find("m4", 1, true) and lines[2]:find("m5", 1, true))
  t.eq(#L.tail(100), 5)
end

function T.disk_full_never_throws()
  local e, L = mk()
  e.capacity = 20
  L.error("x", ("m"):rep(100))
  L.error("x", "again")
end

function T.sink_gets_entries_and_may_fail()
  local got = {}
  local e, L = mk({ sink = function(entry) got[#got + 1] = entry; error("sink down") end })
  L.warn("net", "drop", { n = 1 })
  t.eq(got[1], { ts = 1000, level = "warn", tag = "net", msg = "drop", fields = { n = 1 } })
end

function T.bad_level_is_rejected_at_creation()
  t.err(function() mk({ level = "loud" }) end)
end

return T
