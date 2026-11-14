local t = require("test.t")
local shim = require("test.cc_shim")
local keys_core = require("install.keys_core")
local T = {}

local function counterRandom()
  local n = 0
  return function(len)
    n = n + 1
    return (string.char(n % 256)):rep(len - 1) .. string.char(math.floor(n / 256))
  end
end

function T.generate_is_symmetric_distinct_and_32_bytes()
  local roles = { "storage", "compute", "incoming" }
  local all = keys_core.generate(counterRandom(), roles)
  local seen, n = {}, 0
  for _, a in ipairs(roles) do
    for _, b in ipairs(roles) do
      local k = all[a][b]
      t.eq(#k, 32)
      t.eq(k, all[b][a])
      if not seen[k] then seen[k] = true; n = n + 1 end
    end
  end
  t.eq(n, 6) -- 3 pairs + 3 same-role keys
end

function T.serialise_load_round_trip()
  local all = keys_core.generate(counterRandom(), keys_core.ROLES)
  local e = shim.new()
  e.write("/bs/keys.lua", keys_core.serialise(all.compute))
  local loaded = assert(keys_core.load(e.fs, "/bs/keys.lua"))
  t.eq(loaded, all.compute)
  t.ok(not e.read("/bs/keys.lua"):find("[^\32-\126\n]"), "key file must be plain text")
end

function T.load_rejects_bad_files()
  local e = shim.new()
  t.eq(keys_core.load(e.fs, "/missing.lua"), nil)
  for _, src in ipairs({ "return 5", "return {", 'return { storage = "abc" }', 'return { storage = "' .. ("zz"):rep(32) .. '" }',
    'return { storage = 5 }', 'return { ["bad role"] = "' .. ("ab"):rep(32) .. '" }', "os.reboot() return {}" }) do
    e.write("/k.lua", src)
    t.eq(keys_core.load(e.fs, "/k.lua"), nil, src)
  end
  e.write("/k.lua", "return {}")
  t.eq(keys_core.load(e.fs, "/k.lua"), nil, "an empty key file is useless")
end

function T.default_roles_are_the_base_computers()
  t.eq(keys_core.ROLES, { "compute", "incoming", "ingest", "monitor", "outgoing", "register", "storage" })
end

return T
