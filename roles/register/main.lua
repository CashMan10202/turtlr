-- REGISTER desk program: pair pockets and turtles with players. Works only while the owner
-- (config: owner) stands within detectRange of the Player Detector.
local node = require("lib.node")
local proto = require("lib.proto")
local registrar = require("roles.register.registrar")

local N = node.start("register")
if N.cfg.owner == "CHANGE_ME" then
  error("set your Minecraft name as 'owner' in /bs/role/config.lua, then reboot", 0)
end

local detector
for _, name in ipairs(peripheral.getNames()) do
  local ty = peripheral.getType(name)
  if ty == "playerDetector" or ty == "player_detector" then detector = peripheral.wrap(name) end
end
if not detector then error("no Player Detector attached", 0) end

local regSk, regPk = node.edgeKey("/bs/edge_key.txt")
N.modem.open(proto.CH.ENROLL)

local Rg = registrar.new({
  crypto = N.crypto, rpc = N.rpc, clock = N.clock, cfg = N.cfg, regSk = regSk, regPk = regPk,
  detector = function(range) return detector.getPlayersInRange(range) end,
  transmit = function(frame) N.modem.transmit(proto.CH.ENROLL, proto.CH.ENROLL, frame) end,
})

local REASONS = {
  owner_absent = "The owner must stand at the desk.",
  no_such_code = "No device is showing that code. Is it switched on and close by?",
  ambiguous = "Two devices claimed that code. Restart the device and try again.",
  player_absent = "That player is not standing at the desk.",
  timeout = "The base did not answer. Are COMPUTE and both gateways running?",
}
local function explain(err) return REASONS[err] or ("Failed: " .. tostring(err)) end

local function pause()
  print("")
  write("Press Enter...")
  read()
end

local function pick(title, options)
  print(title)
  for i, o in ipairs(options) do print(("  %d. %s"):format(i, o)) end
  write("Number (Enter = cancel): ")
  return options[tonumber(read())]
end

local function listDevices()
  local res, err = Rg.list()
  if not res then print(explain(err)); return nil end
  if #res.devices == 0 then print("No devices registered yet."); return res.devices end
  for _, d in ipairs(res.devices) do
    print(("#%d %-6s %-16s %s%s"):format(d.id, d.kind, d.player, d.revoked == 1 and "REVOKED " or "",
      d.unlock == 1 and "unlock-pending" or ""))
  end
  return res.devices
end

local function askId(prompt)
  if not listDevices() then return nil end
  write(prompt .. " (device number, Enter = cancel): ")
  return tonumber(read())
end

local function menu()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print("BuildKit registration desk")
    print("Owner at desk: " .. (Rg.ownerPresent() and "yes" or "NO (" .. N.cfg.owner .. " must be here)"))
    local waiting = Rg.pending()
    print("Devices asking to register: " .. #waiting)
    for _, p in ipairs(waiting) do print(("   %s %s  (%s)"):format(p.code:sub(1, 3), p.code:sub(4), p.kind)) end
    print("")
    print("1 Register a device   2 List devices")
    print("3 Revoke a device     4 Restore a device")
    print("5 Unlock a device     6 Refresh")
    write("> ")
    local choice = read()
    print("")
    if choice == "1" then
      write("Code shown on the device: ")
      local code = read():gsub("%s", "")
      local players = Rg.players()
      local player = #players > 0 and pick("Who is it for?", players)
      if not player then
        print(#players == 0 and "Nobody is standing at the desk." or "Cancelled.")
      else
        local res, err = Rg.approve(code, player)
        if res then
          print(("Registered %s #%d for %s."):format(res.kind, res.id, player))
          print("Check number: " .. res.check)
          print("The device must show the same number. If it does not, revoke it.")
        else
          print(explain(err))
        end
      end
      pause()
    elseif choice == "2" then
      listDevices(); pause()
    elseif choice == "3" or choice == "4" or choice == "5" then
      local id = askId(choice == "3" and "Revoke" or choice == "4" and "Restore" or "Unlock")
      if id then
        local res, err
        if choice == "3" then res, err = Rg.revoke(id)
        elseif choice == "4" then res, err = Rg.restore(id)
        else res, err = Rg.unlock(id, true) end
        print(res and "Done." or explain(err))
        if res and choice == "5" then print("The device opens up within a few seconds if it is on.") end
      end
      pause()
    end
  end
end

local function listen()
  while true do
    local _, _, channel, _, payload = os.pullEvent("modem_message")
    if channel == proto.CH.ENROLL then Rg.onFrame(payload) end
  end
end

parallel.waitForAny(N.rpc.pumpLoop, listen, menu)
