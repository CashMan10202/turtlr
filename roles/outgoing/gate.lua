-- OUTGOING gateway logic: seals each reply for exactly one device and sends it out.
-- It holds no list of devices: COMPUTE passes the device's public key with every reply.
local ext = require("lib.extproto")
local proto = require("lib.proto")

local gate = {}
local SEQ = 4096

function gate.new(opts)
  local crypto, cfg, clock = opts.crypto, opts.cfg, opts.clock
  local last = 0
  local G = { stats = { sent = 0, bad = 0, too_big = 0 } }

  -- body = { d = { id, kxPk }, msg = response table }. Returns true or nil plus a reason.
  function G.send(body)
    local d, msg = body.d, body.msg
    if type(d) ~= "table" or type(d.id) ~= "number" or type(d.kxPk) ~= "string" or #d.kxPk ~= 32
        or not proto.validateResponse(msg) then
      G.stats.bad = G.stats.bad + 1
      return nil, "bad_request"
    end
    local counter = math.max(clock() * SEQ, last + 1)
    last = counter
    local frame = ext.sealResponse(crypto, opts.outSk, opts.outPk, d, counter, msg)
    if #frame > cfg.frameMax then
      G.stats.too_big = G.stats.too_big + 1
      return nil, "too_big"
    end
    opts.transmit(frame)
    G.stats.sent = G.stats.sent + 1
    return true
  end

  return G
end

return gate
