local t = require("test.t")
local S = require("lib.schema")

local T = {}

local function bad(spec, v, needle)
  local ok, err = S.check(spec, v)
  t.eq(ok, nil, "accepted " .. t.show(v))
  t.ok(type(err) == "string")
  if needle then t.ok(err:find(needle, 1, true), "error '" .. err .. "' lacks '" .. needle .. "'") end
end

function T.int_ranges()
  local spec = S.int(1, 10)
  t.ok(S.check(spec, 1)); t.ok(S.check(spec, 10))
  bad(spec, 0); bad(spec, 11); bad(spec, 2.5); bad(spec, math.huge); bad(spec, -math.huge)
  bad(spec, 0 / 0); bad(spec, "5"); bad(spec, nil); bad(spec, true)
end

function T.strings()
  t.ok(S.check(S.str(5), "hello"))
  bad(S.str(5), "hello!")
  bad(S.str(5), "a\nb")      -- control characters are not text
  bad(S.str(5), "\200")
  bad(S.str(5), 5)
  t.ok(S.check(S.str(10, "^https://"), "https://a"))
  bad(S.str(10, "^https://"), "http://a")
  t.ok(S.check(S.bytes(4), "\0\255\n\1"))
  bad(S.bytes(4), "12345")
  t.ok(S.check(S.hex(4), "0aF9"))
  bad(S.hex(4), "0af"); bad(S.hex(4), "0afg")
  t.ok(S.check(S.tok(8), "Ab12"))
  bad(S.tok(8), ""); bad(S.tok(8), "a-b"); bad(S.tok(3), "abcd")
end

function T.ids()
  t.ok(S.check(S.id(), "minecraft:stone"))
  t.ok(S.check(S.id(), "create:cogwheel/large_1.x-y"))
  bad(S.id(), "Minecraft:Stone")
  bad(S.id(), "stone")
  bad(S.id(), "a:b:c")
  bad(S.id(), "minecraft:" .. ("x"):rep(100))
  bad(S.id(), "minecraft:stone[facing=north]")
end

function T.enum_and_bool()
  local e = S.enum({ "a", "b" })
  t.ok(S.check(e, "a")); bad(e, "c"); bad(e, 1)
  t.ok(S.check(S.bool(), false)); bad(S.bool(), 0); bad(S.bool(), nil)
end

function T.arrays()
  local a = S.array(S.int(0, 9), 3)
  t.ok(S.check(a, {})); t.ok(S.check(a, { 1, 2, 3 }))
  bad(a, { 1, 2, 3, 4 })
  bad(a, { 1, "x" }, "[2]")
  bad(a, { x = 1 })
  bad(a, { [1] = 1, [3] = 3 })
  bad(a, "no")
end

function T.maps()
  local m = S.map({ a = S.int(0, 9) }, { b = S.bool() })
  t.ok(S.check(m, { a = 1 }))
  t.ok(S.check(m, { a = 1, b = true }))
  bad(m, {}, "a")
  bad(m, { a = 1, c = 2 }, "c")
  bad(m, { a = 1, b = 3 }, "b")
  bad(m, { a = 1, [1] = 2 })
  bad(m, 5)
end

function T.error_path_names_nested_field()
  local m = S.map({ outer = S.map({ list = S.array(S.map({ n = S.int(0, 1) }), 4) }) })
  local _, err = S.check(m, { outer = { list = { { n = 0 }, { n = 7 } } } })
  t.ok(err:find("outer.list[2].n", 1, true), err)
end

local limits = S.map({}, {
  w = S.int(1, 48, 16),
  take = S.enum({ "none", "marked", "all" }, "marked"),
  mine = S.bool(false),
  boxes = S.array(S.int(0, 9), 2),
})

function T.clamp_fills_defaults()
  t.eq(S.clamp(limits, {}, {}), { w = 16, take = "marked", mine = false, boxes = {} })
  t.eq(S.clamp(limits, nil, {}), { w = 16, take = "marked", mine = false, boxes = {} })
end

function T.clamp_lowers_to_owner_max()
  local out = S.clamp(limits, { w = 999, take = "all", mine = true }, { w = 32, take = "marked", mine = false })
  t.eq(out, { w = 32, take = "marked", mine = false, boxes = {} })
  out = S.clamp(limits, { w = 999, take = "all", mine = true }, {})
  t.eq(out, { w = 48, take = "all", mine = true, boxes = {} })
  out = S.clamp(limits, { w = -5, take = "none" }, { take = "all" })
  t.eq(out, { w = 1, take = "none", mine = false, boxes = {} })
end

function T.clamp_ignores_garbage()
  local out = S.clamp(limits, { w = "big", take = 7, mine = "yes", boxes = { 1, 2, 3 }, extra = 1 }, {})
  t.eq(out, { w = 16, take = "marked", mine = false, boxes = {} })
  t.eq(S.clamp(limits, "junk", {}), { w = 16, take = "marked", mine = false, boxes = {} })
  t.eq(S.clamp(limits, { boxes = { 1, 2 } }, {}).boxes, { 1, 2 })
end

return T
