local t = require("test.t")
local T = {}

local function fresh()
  package.loaded["lib.crypto"] = nil
  return require("lib.crypto")
end

local crypto = fresh()
local key = ("k"):rep(32)

function T.random_requires_init()
  -- must run before any init in this process: use a private copy of the wrapper
  local c = fresh()
  if not c.ready() then t.err(function() c.random(8) end) end
  c.init(("seed"):rep(8))
  local a, b = c.random(16), c.random(16)
  t.eq(#a, 16); t.ok(a ~= b)
  t.err(function() fresh().init("short") end)
  crypto = c
end

function T.hash_vectors()
  t.eq(crypto.hashHex("abc"), "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
  t.eq(#crypto.hash(""), 32)
  t.eq(crypto.hex("\0\255\16"), "00ff10")
end

function T.kdf_separates_contexts()
  local a, b = crypto.kdf("ctx one", "material"), crypto.kdf("ctx two", "material")
  t.eq(#a, 32); t.ok(a ~= b)
  t.eq(a, crypto.kdf("ctx one", "material"))
end

function T.seal_open_round_trip()
  for _, msg in ipairs({ "", "hello", ("\0\255"):rep(5000) }) do
    local sealed = crypto.seal(key, 42, msg, "aad")
    t.eq(#sealed, #msg + 16)
    t.eq(crypto.open(key, 42, sealed, "aad"), msg)
  end
  -- large counters (ms * 4096) work and differ
  local big = 1700000000000 * 4096 + 7
  t.eq(crypto.open(key, big, crypto.seal(key, big, "x", ""), ""), "x")
  t.ok(crypto.seal(key, big, "x", "") ~= crypto.seal(key, big + 1, "x", ""))
end

function T.open_rejects_any_change()
  local sealed = crypto.seal(key, 42, "attack at dawn", "aad")
  for i = 1, #sealed do
    local b = sealed:byte(i)
    local bad = sealed:sub(1, i - 1) .. string.char((b + 1) % 256) .. sealed:sub(i + 1)
    t.eq(crypto.open(key, 42, bad, "aad"), nil, "flip at " .. i)
  end
  t.eq(crypto.open(key, 42, sealed, "other"), nil)
  t.eq(crypto.open(key, 43, sealed, "aad"), nil)
  t.eq(crypto.open(("j"):rep(32), 42, sealed, "aad"), nil)
  t.eq(crypto.open(key, 42, sealed:sub(1, 15), "aad"), nil)
  t.eq(crypto.open(key, 42, "", "aad"), nil)
  t.eq(crypto.open(key, 42, 5, "aad"), nil)
  t.eq(crypto.open("shortkey", 42, sealed, "aad"), nil)
end

return T
