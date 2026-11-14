-- Boot file for every BuildKit computer. Runs the role program and restarts it if it crashes.
-- After 5 crashes within 2 minutes it stops, so a broken program cannot reboot-loop forever.
package.path = "/bs/?.lua;/bs/?/init.lua;" .. package.path

local MAIN, CRASH_LOG, CRASHES = "/bs/role/main.lua", "/bs/crash.log", "/bs/.crashes"

local function readAll(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local function writeAll(path, s)
  local h = fs.open(path, "w")
  if h then h.write(s); h.close() end
end

if fs.exists("/bs/.installing") then
  printError("An install did not finish. Run the install program again.")
  return
end

local fn, loadErr = loadfile(MAIN, nil, _ENV)
if not fn then
  printError("Cannot start " .. MAIN .. ": " .. tostring(loadErr))
  printError("Run the install program to set this computer up.")
  return
end

local ok, err = pcall(fn)
if ok then return end

-- crashed: log it (keeping the log small), then reboot unless it keeps happening
local now = os.epoch("utc")
local log = (readAll(CRASH_LOG) or "") .. ("[%d] %s\n"):format(now, tostring(err):sub(1, 2000))
if #log > 12000 then log = log:sub(-8000) end
pcall(writeAll, CRASH_LOG, log)

local count, first = (readAll(CRASHES) or ""):match("^(%d+) (%d+)")
count, first = tonumber(count) or 0, tonumber(first) or now
if now - first > 120000 then count, first = 0, now end
count = count + 1
pcall(writeAll, CRASHES, count .. " " .. first)

printError("Program crashed: " .. tostring(err):sub(1, 200))
if count > 5 then
  printError("Crashed " .. count .. " times in a row. Stopped. See " .. CRASH_LOG)
  return
end
print("Restarting in 10 seconds...")
sleep(10)
os.reboot()
