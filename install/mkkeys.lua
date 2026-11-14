-- Creates and installs the secret link keys for the base computers.
--   mkkeys              make new keys for every role onto the floppy (/disk/bskeys/)
--   mkkeys load <role>  copy this computer's keys from the floppy to /bs/keys.lua
-- Make the keys once, load them on every base computer, then lock the floppy away.
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local keys_core = require("install.keys_core")

local args = { ... }
local DISK = "/disk/bskeys"

if args[1] == "load" then
  local role = args[2]
  if not role then error("usage: mkkeys load <role>", 0) end
  local src = DISK .. "/" .. role .. ".lua"
  if not fs.exists(src) then error("no keys for '" .. role .. "' on the floppy (" .. src .. ")", 0) end
  if not keys_core.load(fs, src) then error("the key file on the floppy is damaged", 0) end
  if fs.exists("/bs/keys.lua") then fs.delete("/bs/keys.lua") end
  fs.copy(src, "/bs/keys.lua")
  print("Keys for " .. role .. " installed. Reboot this computer.")
  return
end

if not fs.exists("/disk") then error("put a floppy disk in a drive next to this computer first", 0) end
if fs.exists(DISK) then
  print("This floppy already has keys. Making new ones means EVERY base computer")
  print("must load keys again. Type YES to replace them:")
  if read() ~= "YES" then print("Nothing changed."); return end
  fs.delete(DISK)
end

local crypto = require("lib.crypto")
print("Gathering randomness...")
crypto.initWithTiming()
print("Now mash the keyboard for a few seconds, then press Enter.")
local mash = {}
while true do
  local ev, key = os.pullEvent()
  if ev == "key" then
    if key == keys.enter then break end
    mash[#mash + 1] = key .. ":" .. os.epoch("utc")
  elseif ev == "char" then
    mash[#mash + 1] = key .. os.clock()
  end
end
crypto.mix(table.concat(mash, ","))

local all = keys_core.generate(crypto.random, keys_core.ROLES)
for _, role in ipairs(keys_core.ROLES) do
  local h = fs.open(DISK .. "/" .. role .. ".lua", "w")
  h.write(keys_core.serialise(all[role]))
  h.close()
end
print("Keys written to the floppy for: " .. table.concat(keys_core.ROLES, ", "))
print("On each base computer run:  mkkeys load <role>")
