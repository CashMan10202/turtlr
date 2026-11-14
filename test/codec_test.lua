local t = require("test.t")
local codec = require("lib.codec")

local T = {}

local sample = { v = 1, t = "job.quote", a = { 1, -5, 2 ^ 40 }, m = { x = true, y = false }, s = "" }

function T.round_trip()
  local out = assert(codec.decode(codec.encode(sample)))
  t.eq(out, sample)
end

function T.round_trip_scalars()
  for _, v in ipairs({ 0, 1, -1, 127, 128, -129, 2 ^ 53, -(2 ^ 53), "", "a\0b", true, false }) do
    local out, err = codec.decode(codec.encode(v))
    t.ok(err == nil, tostring(err))
    t.eq(out, v)
  end
  t.eq(codec.decode(codec.encode({})), {})
end

function T.encode_is_deterministic()
  local a = {}; a.x = 1; a.y = 2; a.z = 3
  local b = {}; b.z = 3; b.y = 2; b.x = 1
  t.eq(codec.encode(a), codec.encode(b))
end

function T.rejects_empty_and_unknown_tag()
  t.eq(codec.decode(""), nil)
  t.eq(codec.decode("\255"), nil)
  t.eq(codec.decode(nil), nil)
  t.eq(codec.decode(42), nil)
end

function T.rejects_every_truncation()
  local frame = codec.encode(sample)
  for i = 0, #frame - 1 do
    local v, err = codec.decode(frame:sub(1, i))
    t.ok(v == nil and type(err) == "string", "prefix " .. i .. " accepted")
  end
end

function T.rejects_trailing_bytes()
  local v, err = codec.decode(codec.encode(sample) .. "x")
  t.eq(v, nil)
  t.ok(err:find("trailing"))
end

function T.rejects_huge_declared_count_without_allocating()
  -- array tag 0x04, varint 2^30 = 80 80 80 80 04, then one byte of data
  local v = codec.decode("\4\128\128\128\128\4\0")
  t.eq(v, nil)
  -- string claiming 2^30 bytes
  t.eq(codec.decode("\3\128\128\128\128\4a"), nil)
  -- never-ending varint
  t.eq(codec.decode("\2" .. ("\255"):rep(40)), nil)
end

function T.rejects_deep_nesting()
  local v = 1
  for _ = 1, 8 do v = { v } end
  t.ok(codec.decode(codec.encode(v)), "depth 8 should be accepted")
  v = { v }
  t.eq(codec.decode(codec.encode(v)), nil)
end

function T.rejects_too_many_items()
  local big = {}
  for i = 1, 5000 do big[i] = 0 end
  t.eq(codec.decode(codec.encode(big)), nil)
  t.ok(codec.decode(codec.encode(big), { maxItems = 6000 }))
end

function T.rejects_duplicate_map_keys()
  -- map, 2 entries, key "a"=true twice
  t.eq(codec.decode("\5\2\1a\1\1a\1"), nil)
end

function T.encode_rejects_unsupported()
  t.err(function() codec.encode(1.5) end)
  t.err(function() codec.encode(0 / 0) end)
  t.err(function() codec.encode(math.huge) end)
  t.err(function() codec.encode(2 ^ 53 + 2) end)
  t.err(function() codec.encode(function() end) end)
  t.err(function() codec.encode({ [1] = 1, x = 2 }) end) -- mixed table
  t.err(function() codec.encode({ [true] = 1 }) end)
  t.err(function() codec.encode({ 1, nil, 3 }) end) -- hole
end

function T.random_garbage_never_throws()
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
  for _ = 1, 2000 do
    local len = rnd(40)
    local bytes = {}
    for i = 1, len do bytes[i] = string.char(i <= 2 and rnd(8) or rnd(256)) end
    local ok, v, err = pcall(codec.decode, table.concat(bytes))
    t.ok(ok, "decode threw: " .. tostring(v))
    t.ok(v ~= nil or err ~= nil or v == false)
  end
end

return T
