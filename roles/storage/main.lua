-- STORAGE manager program. Started by /startup.lua.
local config = require("lib.config")
local specs = require("lib.config_specs")
local crypto = require("lib.crypto")
local proto = require("lib.proto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local log = require("lib.log")
local device = require("roles.storage.device")
local engine = require("roles.storage.engine")
local server = require("roles.storage.server")
local keys_core = require("install.keys_core")

local SNAPSHOT = "/bs/index.snap"

local cfg, cfgErr = config.load(fs, "/bs/role/config.lua", specs.storage)
if not cfg then error(cfgErr, 0) end
local keys, keyErr = keys_core.load(fs, "/bs/keys.lua")
if not keys then error(keyErr, 0) end

local modem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
    modem = peripheral.wrap(name)
    break
  end
end
if not modem then error("no wireless modem attached", 0) end

local devices = device.discover(peripheral)
if #devices == 0 then
  error("no NBT Storage found. Connect them with wired modems (right-click each modem to turn it on).", 0)
end

if not crypto.ready() then crypto.initWithTiming() end
local function clock() return os.epoch("utc") end

local L = log.new({ fs = fs, path = "/bs/log.txt", level = cfg.log.level, keepKB = cfg.log.keepKB, clock = clock })
local B = bus.new({ modem = modem, channel = proto.CH.BUS, role = "storage", instance = cfg.id,
  keys = keys, crypto = crypto, clock = clock })
local R = rpc.new({ bus = B, pull = os.pullEvent, startTimer = os.startTimer, queueEvent = os.queueEvent,
  clock = clock, onError = function(method, err) L.error("rpc", "handler crashed", { method = method, err = err }) end })

local S
local E = engine.new({
  devices = devices, crypto = crypto, replicas = cfg.replicas, shardBytes = cfg.shardBytes,
  deviceMaxBytes = cfg.deviceMaxBytes, clock = clock,
  hot = { jobs = true, players = true, config = true },
  yield = function()
    -- keep announcing ourselves during long operations, and let other coroutines run
    S.beat()
    os.queueEvent("bs_yield")
    os.pullEvent("bs_yield")
  end,
})

S = server.new({
  engine = E, rpc = R, id = cfg.id, clock = clock, log = L,
  scrubEverySecs = math.max(1, math.floor(cfg.scrubMinutes * 60 / #devices)),
  loadSnapshot = function()
    local h = fs.open(SNAPSHOT, "r")
    if not h then return nil end
    local text = h.readAll()
    h.close()
    return text
  end,
  saveSnapshot = function(text)
    -- the snapshot only speeds up boot; skip it when it would crowd the disk
    if #text > 200000 or fs.getFreeSpace("/") < #text + 50000 then
      if fs.exists(SNAPSHOT) then fs.delete(SNAPSHOT) end
      return
    end
    local h = fs.open(SNAPSHOT .. ".tmp", "w")
    h.write(text)
    h.close()
    if fs.exists(SNAPSHOT) then fs.delete(SNAPSHOT) end
    fs.move(SNAPSHOT .. ".tmp", SNAPSHOT)
  end,
})

L.info("storage", "started", { id = cfg.id, devices = #devices })
print(("Storage manager %d: %d NBT Storage blocks. Running."):format(cfg.id, #devices))
parallel.waitForAny(R.pumpLoop, function() S.loop(os.pullEvent, os.startTimer) end)
