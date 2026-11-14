-- COMPUTE request dispatcher. Takes what INCOMING forwarded, checks the device's signature again
-- (so a compromised gateway cannot invent requests), then runs the handler for that message type.
local ext = require("lib.extproto")
local proto = require("lib.proto")
local codec = require("lib.codec")

local dispatch = {}

function dispatch.new(opts)
  local crypto, registry, clock = opts.crypto, opts.registry, opts.clock
  local lastSeen = {}
  local D = { handlers = opts.handlers or {}, stats = { ok = 0, dropped = 0, errors = 0 } }

  local function drop(why)
    D.stats.dropped = D.stats.dropped + 1
    if opts.log then opts.log.warn("dispatch", "request dropped", { why = why }) end
    return nil, why
  end

  -- req = { d = device id, c = counter, m = encoded message, s = signature }
  function D.onRequest(req)
    if type(req) ~= "table" or type(req.c) ~= "number" then return drop("bad_forward") end
    local record = registry.get(req.d)
    if not record then return drop("unknown_device") end
    if record.revoked == 1 then return drop("revoked") end
    if not ext.verifyRequest(crypto, record, req.c, req.m, req.s) then return drop("bad_signature") end
    if req.c <= (lastSeen[record.id] or 0) then return drop("replay") end
    lastSeen[record.id] = req.c
    local msg = codec.decode(req.m)
    if type(msg) ~= "table" or not proto.validate(msg) then return drop("bad_request") end

    local response = { v = proto.VERSION, t = msg.t, re = msg.id, ok = false }
    local handler = D.handlers[msg.t]
    if not handler then
      response.err = "bad_request"
    else
      local ok, body, err = pcall(handler, { dev = record, player = record.player, now = clock() }, msg.b)
      if not ok then
        D.stats.errors = D.stats.errors + 1
        if opts.log then opts.log.error("dispatch", "handler crashed", { t = msg.t, err = body }) end
        response.err = "internal"
      elseif body == nil then
        response.err = err or "internal"
      else
        response.ok, response.b = true, body
      end
    end
    if not proto.validateResponse(response) then
      -- a handler returned something that does not match the protocol: never send it out
      D.stats.errors = D.stats.errors + 1
      if opts.log then opts.log.error("dispatch", "handler returned an invalid reply", { t = msg.t }) end
      response = { v = proto.VERSION, t = msg.t, re = msg.id, ok = false, err = "internal" }
    end
    D.stats.ok = D.stats.ok + 1
    opts.send(record, response)
    return true
  end

  return D
end

return dispatch
