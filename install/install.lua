-- BuildKit installer. Run on the computer you are setting up.
--   install                      (release on a floppy at /disk/buildservice)
--   install <role>               (same, skipping the role menu)
--   install <role> <https url>   (release hosted on the web)
local args = { ... }

-- Find where this installer lives so it can load its helper files from the same release.
local here = fs.getDir(shell.getRunningProgram())      -- .../install
local root = fs.getDir(here)                           -- release root
package.path = "/" .. root .. "/?.lua;" .. package.path

local role, url = args[1], args[2]

-- Web installs start with only this file, so fetch the two helper files it needs first.
if url and not fs.exists("/" .. root .. "/install/installer_core.lua") then
  if not http then error("HTTP is disabled on this server", 0) end
  local base = url:sub(-1) == "/" and url or url .. "/"
  for _, path in ipairs({ "install/installer_core.lua", "lib/sha256.lua" }) do
    local res, err = http.get(base .. path)
    if not res then error("cannot download " .. path .. ": " .. tostring(err), 0) end
    local h = fs.open("/bs/.boot/" .. path, "w")
    h.write(res.readAll()); h.close(); res.close()
  end
  package.path = "/bs/.boot/?.lua;" .. package.path
end

local core = require("install.installer_core")
local fetch
if url then
  if not http then error("HTTP is disabled on this server", 0) end
  if url:sub(1, 8) ~= "https://" then error("the address must start with https://", 0) end
  fetch = core.fetchers.http(http, url)
else
  fetch = core.fetchers.disk(fs, "/" .. root)
end

local src, ferr = fetch("manifest.lua")
if not src then error("cannot read manifest.lua: " .. tostring(ferr), 0) end
local fn, lerr = load(src, "=manifest", "t", {})
if not fn then error("manifest.lua is damaged: " .. tostring(lerr), 0) end
local manifest = fn()

if not role then
  local roles = {}
  for name in pairs(manifest.roles) do roles[#roles + 1] = name end
  table.sort(roles)
  print("BuildKit " .. manifest.version .. " - which role is this computer?")
  for i, name in ipairs(roles) do print(("%2d. %s"):format(i, name)) end
  write("Number: ")
  role = roles[tonumber(read())]
  if not role then error("not a valid choice", 0) end
end

local before = core.installed(fs)
if before and before.role ~= role then
  print("This computer is currently '" .. before.role .. "'. Change it to '" .. role .. "'? (y/n)")
  if read():lower() ~= "y" then return end
end

print("Installing " .. role .. " " .. manifest.version .. " ...")
local ok, err = core.install(fs, fetch, manifest, role, { yield = function() sleep(0) end })
if not ok then
  printError("Install failed, nothing was changed: " .. tostring(err))
  return
end
print("Done. Edit /bs/role/config.lua if needed, then reboot.")
if fs.exists("/bs/role/config.lua.new") then
  print("Your config was kept. The new default is in /bs/role/config.lua.new")
end
