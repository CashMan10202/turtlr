local t = require("test.t")
local shim = require("test.cc_shim")
local sha = require("lib.sha256")
local core = require("install.installer_core")

local T = {}

local src = {
  ["lib/codec.lua"] = "return 'codec v2'",
  ["roles/compute/main.lua"] = "print('compute')",
  ["roles/compute/config.lua"] = "return { fresh = true }",
  ["roles/_common/startup.lua"] = "print('boot')",
  ["roles/gps/main.lua"] = "print('gps')",
}

local function entry(path, dest)
  return { path = path, dest = dest, size = #src[path], sha256 = sha.hex(src[path]) }
end

local function manifest()
  return { version = "0.2.0", roles = {
    compute = {
      entry("lib/codec.lua", "/bs/lib/codec.lua"),
      entry("roles/compute/main.lua", "/bs/role/main.lua"),
      entry("roles/compute/config.lua", "/bs/role/config.lua"),
      entry("roles/_common/startup.lua", "/startup.lua"),
    },
    gps = { entry("roles/gps/main.lua", "/bs/role/main.lua") },
  } }
end

-- a computer with a floppy holding the release
local function setup()
  local e = shim.new()
  for path, content in pairs(src) do e.write("/disk/buildservice/" .. path, content) end
  return e, core.fetchers.disk(e.fs, "/disk/buildservice")
end

-- an "old install" already on the computer
local function oldInstall(e)
  e.write("/bs/lib/codec.lua", "OLD codec")
  e.write("/bs/role/main.lua", "OLD main")
  e.write("/bs/role/config.lua", "return { mine = true }")
  e.write("/startup.lua", "OLD startup")
end

local function assertOldIntact(e)
  t.eq(e.read("/bs/lib/codec.lua"), "OLD codec")
  t.eq(e.read("/bs/role/main.lua"), "OLD main")
  t.eq(e.read("/bs/role/config.lua"), "return { mine = true }")
  t.eq(e.read("/startup.lua"), "OLD startup")
  t.ok(not e.fs.exists("/bs/.installing"))
end

function T.plan_lists_entries_or_rejects_unknown_role()
  t.eq(#assert(core.plan(manifest(), "compute")), 4)
  local p, err = core.plan(manifest(), "nope")
  t.eq(p, nil); t.ok(err:find("nope", 1, true))
  t.eq(core.plan({}, "compute"), nil)
  t.eq(core.plan(nil, "compute"), nil)
end

function T.fresh_install_writes_everything()
  local e, fetch = setup()
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  t.eq(e.read("/bs/lib/codec.lua"), src["lib/codec.lua"])
  t.eq(e.read("/bs/role/main.lua"), src["roles/compute/main.lua"])
  t.eq(e.read("/bs/role/config.lua"), src["roles/compute/config.lua"])
  t.eq(e.read("/startup.lua"), src["roles/_common/startup.lua"])
  t.eq(load(e.read("/bs/.version"), "v", "t", {})(), { role = "compute", version = "0.2.0" })
  t.ok(not e.fs.exists("/bs/.staging"))
  t.ok(not e.fs.exists("/bs/.installing"))
end

function T.upgrade_keeps_existing_config()
  local e, fetch = setup()
  oldInstall(e)
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  t.eq(e.read("/bs/role/config.lua"), "return { mine = true }")
  t.eq(e.read("/bs/role/config.lua.new"), src["roles/compute/config.lua"])
  t.eq(e.read("/bs/lib/codec.lua"), src["lib/codec.lua"])
  -- and a second upgrade replaces the stale .new file without error
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
end

function T.tampered_file_changes_nothing()
  local e, fetch = setup()
  oldInstall(e)
  e.write("/disk/buildservice/roles/compute/main.lua", "print('compute'); evil()")
  local ok, err = core.install(e.fs, fetch, manifest(), "compute")
  t.eq(ok, nil)
  t.ok(err:find("roles/compute/main.lua", 1, true), err)
  assertOldIntact(e)
end

function T.same_size_tamper_is_caught_by_hash()
  local e, fetch = setup()
  oldInstall(e)
  e.write("/disk/buildservice/lib/codec.lua", "return 'codec v3'")
  local ok, err = core.install(e.fs, fetch, manifest(), "compute")
  t.eq(ok, nil)
  t.ok(err:find("hash mismatch: lib/codec.lua", 1, true), err)
  assertOldIntact(e)
end

function T.fetch_failure_midway_changes_nothing()
  local e, fetch = setup()
  oldInstall(e)
  local n = 0
  local flaky = function(path)
    n = n + 1
    if n == 3 then return nil, "disk removed" end
    return fetch(path)
  end
  local ok, err = core.install(e.fs, flaky, manifest(), "compute")
  t.eq(ok, nil); t.ok(err:find("disk removed", 1, true), err)
  assertOldIntact(e)
end

function T.not_enough_space_fails_before_writing()
  local e, fetch = setup()
  oldInstall(e)
  e.capacity = e.capacity - e.fs.getFreeSpace() + 10
  local ok, err = core.install(e.fs, fetch, manifest(), "compute")
  t.eq(ok, nil); t.ok(err:find("space", 1, true), err)
  assertOldIntact(e)
  t.ok(not e.fs.exists("/bs/.staging"))
end

function T.stale_staging_is_cleared()
  local e, fetch = setup()
  e.write("/bs/.staging/bs/lib/junk.lua", "junk")
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  t.ok(not e.fs.exists("/bs/.staging"))
  t.ok(not e.fs.exists("/bs/lib/junk.lua"))
end

function T.upgrade_skips_files_that_did_not_change()
  -- most of a release (the crypto library, for one) never changes; re-copying it wastes scarce disk space
  local e, fetch = setup()
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  local fetched = {}
  local counting = function(path) fetched[#fetched + 1] = path; return fetch(path) end
  src["roles/compute/main.lua"] = "print('compute v2')"
  e.write("/disk/buildservice/roles/compute/main.lua", src["roles/compute/main.lua"])
  -- so little free space that a full re-copy could not fit
  e.capacity = e.capacity - e.fs.getFreeSpace() + 1024 + #src["roles/compute/main.lua"] + 10
  local ok, err = core.install(e.fs, counting, manifest(), "compute")
  src["roles/compute/main.lua"] = "print('compute')"
  t.ok(ok, tostring(err))
  t.eq(fetched, { "roles/compute/main.lua" })
  t.eq(e.read("/bs/role/main.lua"), "print('compute v2')")
  t.eq(e.read("/bs/lib/codec.lua"), src["lib/codec.lua"])
end

function T.a_damaged_installed_file_is_replaced()
  local e, fetch = setup()
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  e.write("/bs/lib/codec.lua", "return 'codec vX'") -- same size, different content
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  t.eq(e.read("/bs/lib/codec.lua"), src["lib/codec.lua"])
end

function T.setup_shortcut_destination_is_allowed()
  local e, fetch = setup()
  local m = manifest()
  m.roles.gps[1].dest = "/setup.lua"
  t.ok(core.install(e.fs, fetch, m, "gps"))
  t.ok(e.fs.exists("/setup.lua"))
end

function T.unsafe_destinations_are_refused()
  local e, fetch = setup()
  for _, dest in ipairs({ "/rom/x.lua", "/bs/../rom/x", "/disk/x.lua", "relative.lua", "/bs/.staging/x" }) do
    local m = manifest()
    m.roles.gps[1].dest = dest
    local ok = core.install(e.fs, fetch, m, "gps")
    t.eq(ok, nil, "accepted dest " .. dest)
  end
end

function T.http_fetcher_reads_and_reports_errors()
  local http = { get = function(url)
    if url == "https://x.test/rel/lib/codec.lua" then
      return { readAll = function() return "DATA" end, close = function() end,
        getResponseCode = function() return 200 end }
    end
    return nil, "Not found"
  end }
  local fetch = core.fetchers.http(http, "https://x.test/rel/")
  t.eq(fetch("lib/codec.lua"), "DATA")
  local v, err = fetch("lib/missing.lua")
  t.eq(v, nil); t.ok(err:find("missing", 1, true))
end

function T.interrupted_swap_leaves_the_marker_so_startup_refuses()
  local e, fetch = setup()
  oldInstall(e)
  local realMove, n = e.fs.move, 0
  e.fs.move = function(a, b)
    n = n + 1
    if n == 2 then error("power lost") end
    return realMove(a, b)
  end
  t.ok(not pcall(core.install, e.fs, fetch, manifest(), "compute"))
  t.ok(e.fs.exists("/bs/.installing"))
  -- running the installer again repairs it
  e.fs.move = realMove
  t.ok(core.install(e.fs, fetch, manifest(), "compute"))
  t.ok(not e.fs.exists("/bs/.installing"))
  t.eq(e.read("/bs/role/main.lua"), src["roles/compute/main.lua"])
end

return T
