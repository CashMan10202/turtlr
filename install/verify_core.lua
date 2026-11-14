-- Checks that the mods on this server behave the way BuildKit expects.
-- Each check returns "PASS", "FAIL" or "SKIP" plus a detail line. Missing hardware is a SKIP.
-- env holds the CC globals (fs, peripheral, os, term, http, gps, turtle, shell, _HOST) and env.flags.
local core = {}

-- Find the first attached peripheral whose type is one of `types`. Returns name, type.
local function find(env, types)
  for _, name in ipairs(env.peripheral.getNames()) do
    local ty = env.peripheral.getType(name)
    for _, want in ipairs(types) do
      if ty == want then return name, ty end
    end
  end
end

local function methods(env, name)
  local list = env.peripheral.getMethods(name) or {}
  local set = {}
  for _, m in ipairs(list) do set[m] = true end
  return set, table.concat(list, ", ")
end

local NBT = { "nbtStorage", "nbt_storage" }
local NBT_READERS = { "load", "read" }
local NBT_WRITERS = { "save", "writeTable", "writeJson" }

local function nbtReader(set)
  for _, m in ipairs(NBT_READERS) do
    if set[m] then return m end
  end
end

local function nbtWriter(set)
  for _, m in ipairs(NBT_WRITERS) do
    if set[m] then return m end
  end
end

-- A peripheral check that only looks at method names.
local function apiCheck(id, desc, types, needAll, needAny)
  return { id = id, desc = desc, run = function(env)
    local name, ty = find(env, types)
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    for _, m in ipairs(needAll) do
      if not set[m] then return "FAIL", "missing " .. m .. "; " .. ty .. " has: " .. listed end
    end
    if needAny then
      local got = false
      for _, m in ipairs(needAny) do got = got or set[m] end
      if not got then
        return "FAIL", "needs one of " .. table.concat(needAny, "/") .. "; " .. ty .. " has: " .. listed
      end
    end
    return "PASS", ty .. ": " .. listed
  end }
end

core.checks = {
  { id = "cc.version", desc = "CC: Tweaked 1.112 or newer", run = function(env)
    local major, minor = tostring(env._HOST):match("ComputerCraft (%d+)%.(%d+)")
    if not major then return "FAIL", "cannot read version from: " .. tostring(env._HOST) end
    major, minor = tonumber(major), tonumber(minor)
    if major > 1 or (major == 1 and minor >= 112) then return "PASS", env._HOST end
    return "FAIL", "too old: " .. env._HOST
  end },

  { id = "fs.capacity", desc = "Disk space on this computer", run = function(env)
    local cap, free = env.fs.getCapacity("/"), env.fs.getFreeSpace("/")
    if type(cap) ~= "number" then return "PASS", "unlimited" end
    return cap >= 500000 and "PASS" or "FAIL", cap .. " bytes total, " .. tostring(free) .. " free"
  end },

  { id = "http", desc = "HTTP enabled (needed for web installs and INGEST)", run = function(env)
    if env.http then return "PASS", "enabled" end
    return "FAIL", "http is disabled in the server config"
  end },

  { id = "gfx", desc = "CC: Graphics pixel mode (--gfx to draw a test)", run = function(env)
    local term = env.term
    if not term then return "SKIP", "no terminal" end
    if not term.setGraphicsMode then return "FAIL", "not available here; the teletext renderer will be used" end
    if not env.flags.gfx then return "PASS", "setGraphicsMode exists (run with --gfx to test drawing)" end
    local ok, err = pcall(function()
      term.setGraphicsMode(1)
      for i = 0, 15 do term.setPixel(i, i, 2 ^ (i % 16)) end
    end)
    pcall(term.setGraphicsMode, 0)
    if not ok then return "FAIL", "drawing failed: " .. tostring(err) end
    return "PASS", "drew 16 pixels and switched back"
  end },

  { id = "nbt.type", desc = "NBT Storage attached", run = function(env)
    local name, ty = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    local _, listed = methods(env, name)
    return "PASS", "type " .. ty .. "; methods: " .. listed
  end },

  { id = "nbt.api", desc = "NBT Storage has read + write methods", run = function(env)
    local name, ty = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    local reader, writer = nbtReader(set), nbtWriter(set)
    if reader and writer then return "PASS", reader .. " + " .. writer end
    return "FAIL", ty .. " has: " .. listed
  end },

  { id = "nbt.size", desc = "NBT Storage size limit (--nbt-write, device must be empty)", run = function(env)
    local name = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    if not env.flags.nbtWrite then return "SKIP", "run with --nbt-write on an EMPTY device to measure" end
    local dev = env.peripheral.wrap(name)
    local set = methods(env, name)
    local reader, writer = nbtReader(set), nbtWriter(set)
    if not (reader and writer) then return "FAIL", "no usable read/write methods" end
    local current = dev[reader]()
    if type(current) == "table" and next(current) ~= nil then return "SKIP", "device is not empty; not touching it" end
    local function try(n)
      local payload = ("x"):rep(n)
      local arg = writer == "writeJson" and ('{"d":"' .. payload .. '"}') or { d = payload }
      local ok, res = pcall(dev[writer], arg)
      if not ok or res == false then return false end
      -- do not trust the return value: read it back and see whether it really was stored
      local back = dev[reader]()
      return type(back) == "table" and type(back.d) == "string" and #back.d == n
    end
    if not try(16) then return "FAIL", writer .. " refused even 16 characters" end
    local lo, hi = 16, 1100000 -- lo is known good, hi is the most we will try
    if try(hi) then
      lo = hi
    else
      while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if try(mid) then lo = mid else hi = mid end
      end
    end
    pcall(dev[writer], writer == "writeJson" and "{}" or {})
    return "PASS", "largest payload accepted: " .. lo .. " characters (via " .. reader .. "/" .. writer .. ")"
  end },

  { id = "geo.api", desc = "Geo Scanner (--scan to time a radius-16 scan)", run = function(env)
    local name, ty = find(env, { "geoScanner", "geo_scanner" })
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    if not set.scan then return "FAIL", ty .. " has no scan; methods: " .. listed end
    if not env.flags.scan then return "PASS", ty .. ": " .. listed end
    local start = env.os.epoch("utc")
    local blocks, err = env.peripheral.call(name, "scan", 16)
    local ms = env.os.epoch("utc") - start
    if type(blocks) ~= "table" then return "FAIL", "scan(16) failed: " .. tostring(err) end
    local sample = blocks[1] and blocks[1].name or "?"
    return "PASS", ("scan(16): %d blocks in %d ms; first: %s"):format(#blocks, ms, tostring(sample))
  end },

  apiCheck("me.api", "ME Bridge can list and craft items", { "meBridge", "me_bridge" },
    { "craftItem" }, { "listItems", "getItems" }),

  apiCheck("pd.api", "Player Detector can find nearby players", { "playerDetector", "player_detector" },
    { "getPlayersInRange" }, { "getPlayerPos", "getPlayer" }),

  { id = "modem", desc = "Modems attached", run = function(env)
    local found = {}
    for _, name in ipairs(env.peripheral.getNames()) do
      if env.peripheral.getType(name) == "modem" then
        found[#found + 1] = name .. (env.peripheral.call(name, "isWireless") and " (wireless/ender)" or " (wired)")
      end
    end
    if #found == 0 then return "SKIP", "none attached" end
    return "PASS", table.concat(found, ", ")
  end },

  { id = "gps", desc = "GPS position fix", run = function(env)
    if not env.gps then return "SKIP", "no gps API or no modem" end
    local x, y, z = env.gps.locate(2)
    if not x then return "FAIL", "no fix: need 4 GPS hosts in range" end
    return "PASS", ("at %s, %s, %s"):format(x, y, z)
  end },

  { id = "turtle.equip", desc = "Turtle can swap tools", run = function(env)
    if not env.turtle then return "SKIP", "not a turtle" end
    if env.turtle.equipLeft and env.turtle.equipRight then return "PASS", "equipLeft/equipRight exist" end
    return "FAIL", "equip functions missing"
  end },

  { id = "inv.generic", desc = "Turtle can read the block in front (chest, backpack, machine)", run = function(env)
    if not env.turtle then return "SKIP", "not a turtle" end
    local ty = env.peripheral.getType("front")
    if not ty then return "SKIP", "nothing readable in front; place a chest there and re-run" end
    local set = methods(env, "front")
    if not set.list then return "FAIL", ty .. " has no list method" end
    local n = 0
    for _ in pairs(env.peripheral.call("front", "list")) do n = n + 1 end
    return "PASS", ty .. ": " .. n .. " used slots"
  end },

  { id = "secureboot", desc = "CCSecureBoot installed (lock test is manual)", run = function(env)
    if not env.shell then return "SKIP", "no shell" end
    if env.shell.resolveProgram("enroll-secure-boot") then
      return "PASS", "enroll-secure-boot found; still test by hand that a locked device has no shell"
    end
    return "FAIL", "enroll-secure-boot program not found"
  end },
}

-- Runs every check. A check that throws becomes a FAIL; the rest still run.
function core.runAll(env)
  env.flags = env.flags or {}
  local results = {}
  for i, c in ipairs(core.checks) do
    local ok, status, detail = pcall(c.run, env)
    if not ok then status, detail = "FAIL", "error: " .. tostring(status) end
    results[i] = { id = c.id, desc = c.desc, status = status, detail = tostring(detail or "") }
  end
  return results
end

function core.report(results)
  local lines = {}
  for i, r in ipairs(results) do
    lines[i] = ("[%s] %-12s %s -- %s"):format(r.status, r.id, r.desc, r.detail)
  end
  return lines
end

return core
