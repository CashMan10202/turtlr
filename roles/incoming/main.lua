-- INCOMING gateway program: the only computer that listens to players' devices.
local node = require("lib.node")
local proto = require("lib.proto")
local gate = require("roles.incoming.gate")

local N = node.start("incoming")
local inSk, inPk = node.edgeKey("/bs/edge_key.txt")
N.ext.open(proto.CH.IN)

local G = gate.new({
  crypto = N.crypto, cfg = N.cfg, clock = N.clock, inSk = inSk, inPk = inPk,
  lookup = function(id)
    local record = N.rpc.call("compute", "dev_get", { id = id }, 3)
    return record
  end,
  forward = function(req) N.rpc.notify("compute", "req", req) end,
})

local handlers = {
  pubkey = function() return { pk = inPk } end,
  dev_drop = function(body, src)
    if src == "compute" and type(body.id) == "number" then G.drop(body.id) end
  end,
  stats = function() return G.stats end,
}

local function listen()
  while true do
    local _, _, channel, _, payload = os.pullEvent("modem_message")
    if channel == proto.CH.IN then
      G.enqueue(payload)
      os.queueEvent("gate_work")
    end
  end
end

local function work()
  while true do
    if not G.processOne() then os.pullEvent("gate_work") end
  end
end

print("INCOMING gateway running.")
parallel.waitForAny(N.rpc.pumpLoop, listen, work, function() N.rpc.serveLoop(handlers) end)
