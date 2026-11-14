-- Test helper: boots a real roles/<role>/main.lua inside a simulated computer.
--   local c = boot.computer(sim, { name = "compute", role = "compute", keys = roleKeys, config = "return {}",
--                                   peripherals = { top = { "modem", modemObject } } })
-- c.e is the fake disk/peripheral shim, c.printed the printed lines, c.failure() any crash message.
local shim = require("test.cc_shim")
local fake_term = require("test.fake_term")
local keys_core = require("install.keys_core")

local boot = {}

local function slurp(path)
  local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end
boot.slurp = slurp

function boot.computer(sim, opts)
  local node = opts.node or sim.node(opts.name)
  local e = opts.e or shim.new()
  local c = { node = node, e = e, printed = {}, term = fake_term.new(opts.w or 51, opts.h or 19) }
  if opts.config then e.write("/bs/role/config.lua", opts.config) end
  if opts.keys then e.write("/bs/keys.lua", keys_core.serialise(opts.keys)) end
  e.attach(opts.modemSide or "top", "modem", node.modem)
  if opts.secondModemSide then e.attach(opts.secondModemSide, "modem", node.modem) end
  for name, p in pairs(opts.peripherals or {}) do e.attach(name, p[1], p[2]) end
  local settingsStore = {}
  c.settings = settingsStore
  local env
  env = setmetatable({
    fs = e.fs, peripheral = e.peripheral, term = c.term,
    colours = setmetatable({}, { __index = function() return 1 end }),
    settings = { set = function(k, v) settingsStore[k] = v end, get = function(k) return settingsStore[k] end,
      save = function() settingsStore.__saved = true end },
    os = { epoch = node.clock, pullEvent = node.pull, pullEventRaw = node.pull, startTimer = node.startTimer,
      queueEvent = node.queueEvent, reboot = function() c.rebooted = (c.rebooted or 0) + 1; node.pull("__halt") end },
    sleep = node.sleep,
    parallel = { waitForAny = function(...)
      for _, fn in ipairs({ ... }) do node.spawn(fn) end
      node.pull("__forever")
    end },
    print = function(...) c.printed[#c.printed + 1] = table.concat({ ... }, " ") end,
    printError = function(...) c.printed[#c.printed + 1] = table.concat({ ... }, " ") end,
    write = function(s) c.printed[#c.printed + 1] = tostring(s) end,
    read = function() return node.pull("__input") end,
  }, { __index = _G })
  -- lib/node.lua uses the computer's globals (fs, peripheral, os), so it must be loaded inside this
  -- fake computer rather than shared; everything else comes from the normal module cache.
  local nodeModule
  env.require = function(name)
    if name == "lib.node" then
      nodeModule = nodeModule or assert(load(slurp("lib/node.lua"), "=lib.node", "t", env))()
      return nodeModule
    end
    return require(name)
  end
  for k, v in pairs(opts.globals or {}) do env[k] = v end
  c.env = env
  local chunk = assert(load(slurp(opts.program or ("roles/" .. opts.role .. "/main.lua")), "=" .. opts.role, "t", env))
  local failure
  function c.failure() return failure end
  node.spawn(function()
    local ok, err = pcall(chunk)
    if not ok then failure = err end
  end)
  return c
end

return boot
