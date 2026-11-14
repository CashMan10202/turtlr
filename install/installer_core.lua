-- Installer logic, kept free of screen/keyboard code so it can be tested outside Minecraft.
-- Safety rule: every file is downloaded and hash-checked into /bs/.staging first.
-- Only when ALL files are verified are they moved into place.
local sha256 = require("lib.sha256")

local core = {}

local STAGING = "/bs/.staging"
local MARKER = "/bs/.installing"

local function safeDest(dest)
  if type(dest) ~= "string" or dest:sub(1, 1) ~= "/" then return false end
  for part in dest:gmatch("[^/]+") do
    if part == ".." or part == "." then return false end
  end
  if dest == "/startup.lua" then return true end
  if dest:sub(1, #STAGING) == STAGING then return false end
  return dest:sub(1, 4) == "/bs/" and #dest > 4
end

-- Returns the list of files for a role, or nil plus an error.
function core.plan(manifest, role)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or type(manifest.version) ~= "string" then
    return nil, "manifest is not valid"
  end
  local entries = manifest.roles[role]
  if type(entries) ~= "table" or #entries == 0 then return nil, "unknown role: " .. tostring(role) end
  for _, e in ipairs(entries) do
    if type(e) ~= "table" or type(e.path) ~= "string" or type(e.size) ~= "number"
        or type(e.sha256) ~= "string" or not safeDest(e.dest) then
      return nil, "manifest entry is not valid: " .. tostring(type(e) == "table" and e.path or e)
    end
  end
  return entries
end

core.fetchers = {}

-- Read release files from a folder (a floppy disk).
function core.fetchers.disk(fs, root)
  return function(path)
    local h = fs.open(root .. "/" .. path, "rb")
    if not h then return nil, "cannot read " .. path end
    local data = h.readAll()
    h.close()
    return data
  end
end

-- Download release files from a web address.
function core.fetchers.http(http, baseUrl)
  if baseUrl:sub(-1) ~= "/" then baseUrl = baseUrl .. "/" end
  return function(path)
    local res, err = http.get(baseUrl .. path, nil, true)
    if not res then return nil, "cannot download " .. path .. ": " .. tostring(err) end
    local data = res.readAll()
    res.close()
    return data
  end
end

local function writeFile(fs, path, data)
  local h, err = fs.open(path, "wb")
  if not h then error(tostring(err)) end
  h.write(data)
  h.close()
end

local function isRoleConfig(dest) return dest == "/bs/role/config.lua" end

-- Installs a role. opts.yield (optional) is called between files so long installs do not time out.
-- Returns true, or nil plus an error. On error nothing outside /bs/.staging has changed.
function core.install(fs, fetch, manifest, role, opts)
  local entries, err = core.plan(manifest, role)
  if not entries then return nil, err end
  local yield = opts and opts.yield or function() end

  if fs.exists(STAGING) then fs.delete(STAGING) end
  local need = 0
  for _, e in ipairs(entries) do need = need + e.size end
  if fs.getFreeSpace("/") < need + 1024 then
    return nil, "not enough free space: need " .. (need + 1024) .. " bytes, have " .. fs.getFreeSpace("/")
  end

  -- 1. download + verify everything into staging
  local ok, why = pcall(function()
    for _, e in ipairs(entries) do
      local data, ferr = fetch(e.path)
      if not data then error(ferr or ("cannot fetch " .. e.path), 0) end
      if #data ~= e.size then error("size mismatch: " .. e.path, 0) end
      if sha256.hex(data) ~= e.sha256:lower() then error("hash mismatch: " .. e.path, 0) end
      writeFile(fs, STAGING .. e.dest, data)
      yield()
    end
  end)
  if not ok then
    pcall(fs.delete, STAGING)
    return nil, tostring(why)
  end

  -- 2. swap into place. The marker makes startup refuse to run a half-swapped install.
  writeFile(fs, MARKER, "1")
  for _, e in ipairs(entries) do
    local dest = e.dest
    if isRoleConfig(dest) and fs.exists(dest) then dest = dest .. ".new" end
    if fs.exists(dest) then fs.delete(dest) end
    fs.move(STAGING .. e.dest, dest)
  end
  writeFile(fs, "/bs/.version", ("return { role = %q, version = %q }\n"):format(role, manifest.version))
  fs.delete(STAGING)
  fs.delete(MARKER)
  return true
end

-- Reads /bs/.version. Returns { role, version } or nil.
function core.installed(fs)
  local h = fs.open("/bs/.version", "r")
  if not h then return nil end
  local src = h.readAll()
  h.close()
  local fn = load(src, "=version", "t", {})
  local ok, v = pcall(fn or error)
  if ok and type(v) == "table" then return v end
end

return core
