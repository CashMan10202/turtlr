-- Shared setup for storage engine tests.
local fake_nbt = require("test.fake_nbt")
local device = require("roles.storage.device")
local crypto = require("lib.crypto")
local engine = require("roles.storage.engine")
if not crypto.ready() then crypto.init(("engine-test-seed"):rep(3)) end

local H = {}

-- a rack of n fake devices sharing one "power" switch
function H.rack(n, limit)
  local rack = { power = { writesLeft = math.huge }, devs = {}, ctl = {} }
  for i = 1, n do
    local p, ctl = fake_nbt.new({ limit = limit or 4000, power = rack.power })
    local methods = {}
    for k in pairs(p) do methods[#methods + 1] = k end
    rack.devs[i] = device.wrap(("nbt_%02d"):format(i), p, methods)
    rack.ctl[i] = ctl
  end
  function rack.writes()
    local n2 = 0
    for _, c in ipairs(rack.ctl) do n2 = n2 + c.writes end
    return n2
  end
  function rack.reads()
    local n2 = 0
    for _, c in ipairs(rack.ctl) do n2 = n2 + c.reads end
    return n2
  end
  function rack.cells()
    local n2 = 0
    for _, c in ipairs(rack.ctl) do n2 = n2 + #c.keys() end
    return n2
  end
  return rack
end

-- a new engine over the rack (like a storage computer booting), already rebuilt
function H.boot(rack, opts)
  opts = opts or {}
  local E = engine.new({
    devices = rack.devs, crypto = crypto,
    replicas = opts.replicas or 2, shardBytes = opts.shardBytes or 300,
    deviceMaxBytes = opts.deviceMaxBytes or 4000,
    hot = opts.hot, cacheBytes = opts.cacheBytes,
    clock = function() return 1700000000000 end,
  })
  E.rebuild()
  return E
end

-- deterministic pseudo-random binary data
function H.blob(n, seed)
  local out, s = {}, seed or 1
  for i = 1, n do
    s = (s * 1103515245 + 12345) % 2147483648
    out[i] = string.char(math.floor(s / 65536) % 256)
  end
  return table.concat(out)
end

return H
