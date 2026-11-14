local t = require("test.t")
local shim = require("test.cc_shim")

local T = {}

-- Runs roles/_common/startup.lua inside a fake computer. mainSrc is the role program.
local function boot(e, mainSrc)
  local log = { printed = {}, rebooted = false, slept = 0 }
  if mainSrc then e.write("/bs/role/main.lua", mainSrc) end
  local env = setmetatable({
    fs = e.fs,
    package = { path = "?.lua" },
    print = function(...) log.printed[#log.printed + 1] = table.concat({ ... }, " ") end,
    printError = function(...) log.printed[#log.printed + 1] = table.concat({ ... }, " ") end,
    sleep = function(n) log.slept = log.slept + n end,
    os = { epoch = e.os.epoch, reboot = function() log.rebooted = true end,
      pullEvent = "normal", pullEventRaw = "raw" },
    loadfile = function(path, _, env)
      local src = e.read(path)
      if not src then return nil, "File not found" end
      return load(src, "=" .. path, "t", env)
    end,
    RAN = function(v) log.ran = v end,
    PULL = function() return rawget(_G, "__never") end,
  }, { __index = _G })
  local f = assert(io.open("roles/_common/startup.lua"))
  local src = f:read("*a"); f:close()
  assert(load(src, "=startup", "t", env))()
  log.path = env.package.path
  log.pullEvent = env.os.pullEvent
  return log
end

function T.runs_the_role_program_with_the_library_path()
  local e = shim.new()
  local log = boot(e, "RAN(package.path)")
  t.ok(log.ran:find("/bs/?.lua", 1, true))
  t.ok(not log.rebooted)
  t.ok(not e.fs.exists("/bs/crash.log"))
end

function T.half_finished_install_refuses_to_run()
  local e = shim.new()
  e.write("/bs/.installing", "1")
  local log = boot(e, "RAN(true)")
  t.eq(log.ran, nil)
  t.ok(table.concat(log.printed, " "):find("install", 1, true))
  t.ok(not log.rebooted)
end

function T.missing_program_does_not_reboot_loop()
  local log = boot(shim.new(), nil)
  t.ok(not log.rebooted)
  t.ok(#log.printed > 0)
end

function T.crash_is_logged_then_reboots()
  local e = shim.new()
  e.setTime(1000000)
  local log = boot(e, "error('boom')")
  t.ok(e.read("/bs/crash.log"):find("boom", 1, true))
  t.eq(log.slept, 10)
  t.ok(log.rebooted)
end

function T.five_fast_crashes_halt()
  local e = shim.new()
  e.setTime(1000000)
  local log
  for i = 1, 5 do
    e.setTime(1000000 + i * 11000)
    log = boot(e, "error('boom')")
    t.ok(log.rebooted, "crash " .. i .. " should reboot")
  end
  e.setTime(1000000 + 6 * 11000)
  log = boot(e, "error('boom')")
  t.ok(not log.rebooted, "sixth fast crash must halt")
  t.ok(table.concat(log.printed, " "):find("crash.log", 1, true))
end

function T.slow_crashes_keep_rebooting()
  local e = shim.new()
  for i = 1, 8 do
    e.setTime(i * 3600000)
    t.ok(boot(e, "error('boom')").rebooted)
  end
end

function T.unlocked_computers_keep_normal_ctrl_t()
  t.eq(boot(shim.new(), "RAN(true)").pullEvent, "normal")
end

function T.locked_device_ignores_ctrl_t()
  local e = shim.new()
  e.write("/bs/.locked", "1")
  t.eq(boot(e, "RAN(true)").pullEvent, "raw")
end

function T.locked_device_restarts_if_its_program_ends()
  local e = shim.new()
  e.write("/bs/.locked", "1")
  t.ok(boot(e, "RAN(true)").rebooted, "a locked device must not fall through to a prompt")
end

function T.device_that_unlocked_itself_drops_to_the_prompt()
  local e = shim.new()
  e.write("/bs/.locked", "1")
  local log = boot(e, "fs.delete('/bs/.locked')")
  t.ok(not log.rebooted)
end

function T.locked_device_never_ends_at_a_prompt_after_repeated_crashes()
  local e = shim.new()
  e.write("/bs/.locked", "1")
  local log
  for i = 1, 8 do
    e.setTime(1000000 + i * 11000)
    log = boot(e, "error('boom')")
    t.ok(log.rebooted, "crash " .. i .. " ended at a prompt")
  end
  t.ok(table.concat(log.printed, " "):find("return it to the owner", 1, true))
  t.eq(log.slept, 60)
end

function T.crash_log_stays_small()
  local e = shim.new()
  for i = 1, 40 do
    e.setTime(i * 3600000)
    boot(e, "error(('x'):rep(2000))")
  end
  t.ok(#e.read("/bs/crash.log") <= 16384)
end

return T
