-- BuildKit verify: checks the mods on this server behave as expected.
--   verify              safe checks only
--   verify --gfx        also draw a pixel test (CC: Graphics)
--   verify --scan       also time a radius-16 Geo Scanner scan (uses turtle fuel)
--   verify --nbt-write  also measure the NBT Storage size limit (ONLY on an empty NBT Storage)
-- Writes the result to /verify_report.txt
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local core = require("install.verify_core")

local flags = {}
for _, a in ipairs({ ... }) do
  if a == "--gfx" then flags.gfx = true
  elseif a == "--scan" then flags.scan = true
  elseif a == "--nbt-write" then flags.nbtWrite = true
  else error("unknown option " .. a .. " (use --gfx, --scan, --nbt-write)", 0) end
end

local results = core.runAll({
  _HOST = _HOST, fs = fs, http = http, term = term, peripheral = peripheral, os = os,
  gps = gps, turtle = turtle, shell = shell, flags = flags,
})

local kind = turtle and "turtle" or pocket and "pocket" or "computer"
local header = ("BuildKit verify - %s #%d %s"):format(kind, os.getComputerID(), os.getComputerLabel() or "")
local colour = { PASS = colours.lime, FAIL = colours.red, SKIP = colours.lightGrey }

print(header)
for _, r in ipairs(results) do
  if term.isColour() then term.setTextColour(colour[r.status] or colours.white) end
  write("[" .. r.status .. "] ")
  term.setTextColour(colours.white)
  print(r.id .. ": " .. r.detail)
end

local h = fs.open("/verify_report.txt", "w")
h.write(header .. "\n" .. table.concat(core.report(results), "\n") .. "\n")
h.close()
print("Saved to /verify_report.txt")
