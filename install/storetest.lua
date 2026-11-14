-- In-game check of the storage service. Run on the COMPUTE computer (it has the compute keys):
--   /bs/install/storetest
-- Stores, reads back, lists and deletes test values and prints timings. Uses the key prefix "selftest-".
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local crypto = require("lib.crypto")
local proto = require("lib.proto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local storeclient = require("lib.storeclient")
local keys_core = require("install.keys_core")

local keys, err = keys_core.load(fs, "/bs/keys.lua")
if not keys then error(err, 0) end
if not keys.storage then error("this computer's keys cannot talk to storage (run on COMPUTE)", 0) end
local modem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then modem = peripheral.wrap(name) end
end
if not modem then error("no wireless modem attached", 0) end

print("Gathering randomness...")
if not crypto.ready() then crypto.initWithTiming() end
local function clock() return os.epoch("utc") end
local B = bus.new({ modem = modem, channel = proto.CH.BUS, role = "compute", instance = 99, keys = keys,
  crypto = crypto, clock = clock })
local R = rpc.new({ bus = B, pull = os.pullEvent, startTimer = os.startTimer, queueEvent = os.queueEvent, clock = clock })
local store = storeclient.new({ rpc = R, sleep = sleep })

local failed = 0
local function step(name, fn)
  local start = clock()
  local ok, detail = fn()
  local ms = clock() - start
  if term.isColour() then term.setTextColour(ok and colours.lime or colours.red) end
  write(ok and "[PASS] " or "[FAIL] ")
  term.setTextColour(colours.white)
  print(("%s (%d ms) %s"):format(name, ms, detail and tostring(detail) or ""))
  if not ok then failed = failed + 1 end
end

local function tests()
  local small = "hello " .. clock()
  local big = {}
  for i = 1, 2000 do big[i] = ("%05d:"):format(i) .. string.char(i % 256):rep(44) end
  big = table.concat(big) -- 100 KB including every byte value

  step("health", function()
    local h, e = store.health()
    if not h then return false, e .. " - is a storage manager running and primary?" end
    return true, ("%d devices, %d keys, %d/%d bytes, degraded %d, lost %d")
      :format(h.devices, h.keys, h.used, h.capacity, h.degraded, h.lost)
  end)
  step("put small", function() return store.put("config", "selftest-small", small) end)
  step("get small", function()
    local v, e = store.get("config", "selftest-small")
    return v == small, e
  end)
  step("put 100 KB", function() return store.put("config", "selftest-big", big) end)
  step("get 100 KB", function()
    local v, e = store.get("config", "selftest-big")
    return v == big, e or (v and "data differs!" or nil)
  end)
  step("list", function()
    local keysFound, e = store.list("config", "selftest-")
    return keysFound and #keysFound == 2, e or (keysFound and #keysFound .. " keys")
  end)
  step("delete", function()
    return store.delete("config", "selftest-small") and store.delete("config", "selftest-big")
  end)
  step("gone after delete", function()
    local _, e = store.get("config", "selftest-small")
    return e == "not_found", e
  end)
  print(failed == 0 and "All storage checks passed." or (failed .. " check(s) failed."))
end

parallel.waitForAny(R.pumpLoop, tests)
