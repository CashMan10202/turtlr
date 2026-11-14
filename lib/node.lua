-- Common start-up for base computers: config, keys, modem, log, encrypted bus and rpc.
--   local N = node.start("compute")
--   N.cfg, N.keys, N.log, N.bus, N.rpc, N.clock, N.modem, N.ext (edge computers only)
local config = require("lib.config")
local specs = require("lib.config_specs")
local crypto = require("lib.crypto")
local proto = require("lib.proto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local log = require("lib.log")
local keys_core = require("install.keys_core")

local node = {}

local function wirelessOn(side)
  if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
    return peripheral.wrap(side)
  end
end

function node.start(role, opts)
  opts = opts or {}
  local cfg, cfgErr = config.load(fs, "/bs/role/config.lua", specs[role])
  if not cfg then error(cfgErr, 0) end
  local keys, keyErr = keys_core.load(fs, "/bs/keys.lua")
  if not keys then error(keyErr, 0) end

  local modem, ext
  if cfg.busSide then
    -- edge computer: two modems, told apart by the side they are on
    modem = wirelessOn(cfg.busSide)
    ext = wirelessOn(cfg.extSide)
    if not modem then error("no wireless modem on the " .. cfg.busSide .. " side (busSide in config)", 0) end
    if not ext then error("no ender modem on the " .. cfg.extSide .. " side (extSide in config)", 0) end
  else
    for _, name in ipairs(peripheral.getNames()) do
      modem = modem or wirelessOn(name)
    end
    if not modem then error("no wireless modem attached", 0) end
  end

  if not crypto.ready() then crypto.initWithTiming() end
  local function clock() return os.epoch("utc") end
  local L = log.new({ fs = fs, path = "/bs/log.txt", level = cfg.log.level, keepKB = cfg.log.keepKB, clock = clock })
  local B = bus.new({ modem = modem, channel = proto.CH.BUS, role = role, instance = opts.instance or 1,
    keys = keys, crypto = crypto, clock = clock })
  local R = rpc.new({ bus = B, pull = os.pullEvent, startTimer = os.startTimer, queueEvent = os.queueEvent,
    clock = clock, onError = function(method, err) L.error("rpc", "handler crashed", { method = method, err = err }) end })
  L.info(role, "started")
  return { role = role, cfg = cfg, keys = keys, crypto = crypto, clock = clock, log = L, bus = B, rpc = R,
    modem = modem, ext = ext }
end

-- An edge computer's own key pair, created on first start and kept on its disk.
function node.edgeKey(path)
  local function hex(b) return (b:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
  local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end
  local h = fs.open(path, "r")
  if h then
    local sk, pk = h.readAll():match("^(%x+) (%x+)")
    h.close()
    if sk and #sk == 64 and #pk == 64 then return unhex(sk), unhex(pk) end
  end
  local sk, pk = crypto.kxKeypair()
  h = fs.open(path, "w")
  h.write(hex(sk) .. " " .. hex(pk))
  h.close()
  return sk, pk
end

return node
