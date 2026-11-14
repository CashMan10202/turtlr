-- Device-side connection to the base: send a request through INCOMING, wait for the reply from OUTGOING.
--   local C = devclient.new{ crypto, modem, identity, clock, pull, startTimer }
--   local body, err = C.request("hello", { client = "0.3.0", caps = 2 })
local ext = require("lib.extproto")
local proto = require("lib.proto")

local devclient = {}
local SEQ = 4096

function devclient.new(opts)
  local crypto, modem, id, clock = opts.crypto, opts.modem, opts.identity, opts.clock
  local pull, startTimer = opts.pull, opts.startTimer
  local lastSent, lastHeard, nextId = 0, 0, clock() % 100000
  local C = {}

  modem.open(proto.CH.OUT)

  -- Returns the reply body, or nil plus an error code ("timeout", "bad_request", or the server's).
  function C.request(msgType, body, timeoutSecs, tries)
    nextId = nextId + 1
    local msg = { v = proto.VERSION, t = msgType, id = nextId, ts = clock(), b = body or {} }
    local ok = proto.validate(msg)
    if not ok then return nil, "bad_request" end -- a bug on our side: never send it
    for _ = 1, tries or 2 do
      local counter = math.max(clock() * SEQ, lastSent + 1)
      lastSent = counter
      msg.ts = clock()
      modem.transmit(proto.CH.IN, proto.CH.OUT, ext.sealRequest(crypto, id, counter, msg))
      local timer = startTimer(timeoutSecs or 4)
      while true do
        local ev, a, channel, _, payload = pull()
        if ev == "timer" and a == timer then break end
        if ev == "modem_message" and channel == proto.CH.OUT then
          local got = ext.openResponse(crypto, id, payload)
          if got and got.counter > lastHeard and got.msg.re == msg.id and got.msg.t == msgType
              and proto.validateResponse(got.msg) then
            lastHeard = got.counter
            if got.msg.ok then return got.msg.b end
            return nil, got.msg.err
          end
        end
      end
    end
    return nil, "timeout"
  end

  return C
end

return devclient
