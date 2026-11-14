-- WORKER program (Phase 3): registers at the owner's desk, then keeps a connection to the base.
local crypto = require("lib.crypto")
local devapp = require("lib.devapp")

local modem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then modem = peripheral.wrap(name) end
end
if not modem then error("this device needs an ender modem", 0) end

term.clear()
term.setCursorPos(1, 1)
print("Starting...")
if not crypto.ready() then crypto.initWithTiming() end

local function show(lines)
  term.clear()
  for i, text in ipairs(lines) do
    term.setCursorPos(1, i)
    term.write(text)
  end
end

local result = devapp.run({
  fs = fs, settings = settings, crypto = crypto, modem = modem, kind = "worker",
  clock = function() return os.epoch("utc") end,
  pull = os.pullEvent, startTimer = os.startTimer, show = show,
  caps = term.setGraphicsMode and 2 or 1,
})
if result == "unlocked" then
  term.setCursorPos(1, 4)
  print("Type 'setup' for the setup screen.")
end
