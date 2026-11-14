-- OUTGOING gateway program: the only computer that sends to players' devices.
local node = require("lib.node")
local proto = require("lib.proto")
local gate = require("roles.outgoing.gate")

local N = node.start("outgoing")
local outSk, outPk = node.edgeKey("/bs/edge_key.txt")

local G = gate.new({ crypto = N.crypto, cfg = N.cfg, clock = N.clock, outSk = outSk, outPk = outPk,
  transmit = function(frame) N.ext.transmit(proto.CH.OUT, proto.CH.OUT, frame) end })

local handlers = {
  -- replies come from COMPUTE only
  res = function(body, src)
    if src ~= "compute" then return nil, "not_allowed" end
    local ok, err = G.send(body)
    if not ok then N.log.warn("outgoing", "reply not sent", { reason = err }) end
  end,
  pubkey = function() return { pk = outPk } end,
  stats = function() return G.stats end,
}

print("OUTGOING gateway running.")
parallel.waitForAny(N.rpc.pumpLoop, function() N.rpc.serveLoop(handlers) end)
