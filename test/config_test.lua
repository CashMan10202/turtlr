local t = require("test.t")
local shim = require("test.cc_shim")
local S = require("lib.schema")
local config = require("lib.config")
local specs = require("lib.config_specs")

local T = {}

local spec = S.map({ name = S.str(8) }, {
  size = S.int(1, 10, 4),
  on = S.bool(true),
  inner = S.map({}, { depth = S.int(0, 5, 2) }),
  list = S.array(S.int(0, 9), 3),
})

local function env(src)
  local e = shim.new()
  e.write("/c.lua", src)
  return e
end

function T.loads_and_fills_defaults()
  local cfg = assert(config.load(env('return { name = "a" }').fs, "/c.lua", spec))
  t.eq(cfg, { name = "a", size = 4, on = true, inner = { depth = 2 }, list = {} })
end

function T.explicit_false_is_kept()
  local cfg = assert(config.load(env('return { name = "a", on = false, size = 9 }').fs, "/c.lua", spec))
  t.eq(cfg.on, false)
  t.eq(cfg.size, 9)
end

function T.code_in_config_cannot_reach_anything()
  _G.__config_test_touched = nil
  local cfg, err = config.load(env('__config_test_touched = true; os.shutdown(); return { name = "a" }').fs,
    "/c.lua", spec)
  t.eq(cfg, nil)
  t.ok(type(err) == "string")
  t.eq(_G.__config_test_touched, nil)
end

function T.rejects_non_table_syntax_error_and_missing()
  t.eq(config.load(env("return 5").fs, "/c.lua", spec), nil)
  t.eq(config.load(env("return {").fs, "/c.lua", spec), nil)
  local _, err = config.load(shim.new().fs, "/nope.lua", spec)
  t.ok(err:find("nope.lua", 1, true))
end

function T.out_of_range_names_the_key()
  local _, err = config.load(env('return { name = "a", inner = { depth = 9 } }').fs, "/c.lua", spec)
  t.ok(err:find("inner.depth", 1, true), err)
  _, err = config.load(env('return { name = "a", typo = 1 }').fs, "/c.lua", spec)
  t.ok(err:find("typo", 1, true), err)
end

function T.save_then_load_round_trips()
  local e = shim.new()
  local cfg = { name = "it's", size = 7, on = false, inner = { depth = 0 }, list = { 1, 2 } }
  assert(config.save(e.fs, "/dir/c.lua", cfg))
  t.eq(config.load(e.fs, "/dir/c.lua", spec), cfg)
  t.ok(not e.fs.exists("/dir/c.lua.tmp"))
  cfg.size = 8
  assert(config.save(e.fs, "/dir/c.lua", cfg)) -- overwrite existing
  t.eq(config.load(e.fs, "/dir/c.lua", spec).size, 8)
end

function T.save_failure_keeps_old_file()
  local e = shim.new()
  assert(config.save(e.fs, "/c.lua", { name = "old" }))
  e.capacity = 30
  local ok = config.save(e.fs, "/c.lua", { name = "new", list = { 1, 2, 3 }, inner = { depth = 1 } })
  t.eq(ok, nil)
  t.eq(config.load(e.fs, "/c.lua", spec).name, "old")
end

-- real files on disk, read through a minimal fs adapter
local realfs = {
  open = function(path)
    local f = io.open(path, "r")
    if not f then return nil, "No such file" end
    return { readAll = function() return f:read("*a") end, close = function() f:close() end }
  end,
}

local roles = { "storage", "compute", "incoming", "outgoing", "register", "ingest", "monitor", "worker",
  "pocket", "gps" }

function T.every_shipped_role_config_loads()
  for _, role in ipairs(roles) do
    t.ok(specs[role], "no spec for " .. role)
    local cfg, err = config.load(realfs, "roles/" .. role .. "/config.lua", specs[role])
    t.ok(cfg, role .. ": " .. tostring(err))
  end
end

function T.owner_turtle_maximums_are_valid_turtle_limits()
  local proto = require("lib.proto")
  local cfg = assert(config.load(realfs, "roles/compute/config.lua", specs.compute))
  t.ok(S.check(proto.TURTLE_LIMITS, cfg.turtleMax))
  t.eq(cfg.limits.jobBlocks, 20000)
  t.eq(cfg.limits.jobsActive, 3)
end

return T
