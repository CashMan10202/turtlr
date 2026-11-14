-- Encrypted internal bus between base computers.
-- Every frame is sealed with a key shared by exactly two roles, and carries a counter that
-- only ever goes up, so recorded frames cannot be replayed.
--
--   local B = bus.new{ modem = modem, channel = 4210, role = "compute", instance = 1,
--                      keys = { storage = <32 bytes>, ... }, crypto = crypto, clock = function() return os.epoch("utc") end }
--   B.send("storage", { m = "get", key = "a" })
--   local got = B.receive(channel, payload)   -- from a modem_message event; got = { src, instance, msg }
local codec = require("lib.codec")
local S = require("lib.schema")

local bus = {}

bus.MAX_PAYLOAD = 65536
bus.SKEW_MS = 120000
local SEQ = 4096 -- counter = milliseconds * SEQ + sequence

local frameSpec = S.map({
  s = S.str(16, "^[a-z]+$"),         -- sender role
  i = S.int(0, 255),                 -- sender instance
  d = S.str(16, "^[a-z]+$"),         -- destination role
  c = S.int(1, 2 ^ 53),              -- counter
  p = S.bytes(bus.MAX_PAYLOAD + 64), -- sealed payload
})

function bus.new(opts)
  local modem, channel, role, instance = opts.modem, opts.channel, opts.role, opts.instance or 1
  local keys, crypto, clock = opts.keys, opts.crypto, opts.clock
  local lastSent = 0
  local lastSeen = {} -- "role:instance" -> highest counter accepted
  local B = { role = role, instance = instance, channel = channel }

  modem.open(channel)

  -- Returns true, or nil plus "no_key" / "bad_msg" / "too_big".
  function B.send(dst, msg)
    local key = keys[dst]
    if not key then return nil, "no_key" end
    local ok, plain = pcall(codec.encode, msg)
    if not ok then return nil, "bad_msg" end
    if #plain > bus.MAX_PAYLOAD then return nil, "too_big" end
    local counter = math.max(clock() * SEQ, lastSent + 1)
    lastSent = counter
    local sealed = crypto.seal(key, counter, plain, role .. "|" .. instance .. "|" .. dst)
    modem.transmit(channel, channel, codec.encode({ s = role, i = instance, d = dst, c = counter, p = sealed }))
    return true
  end

  -- Returns { src, instance, msg }, or nil plus the reason the frame was dropped.
  function B.receive(ch, payload)
    if ch ~= channel then return nil, "not_for_me" end
    local frame = codec.decode(payload, { maxItems = 16 })
    if type(frame) ~= "table" or not S.check(frameSpec, frame) then return nil, "bad_frame" end
    if frame.d ~= role then return nil, "not_for_me" end
    local key = keys[frame.s]
    if not key then return nil, "no_key" end
    local plain = crypto.open(key, frame.c, frame.p, frame.s .. "|" .. frame.i .. "|" .. frame.d)
    if not plain then return nil, "bad_auth" end
    -- authenticated from here on
    local who = frame.s .. ":" .. frame.i
    if frame.c <= (lastSeen[who] or 0) then return nil, "replay" end
    local age = clock() - math.floor(frame.c / SEQ)
    if age > bus.SKEW_MS or age < -bus.SKEW_MS then return nil, "stale" end
    local msg = codec.decode(plain)
    if type(msg) ~= "table" then return nil, "bad_frame" end
    lastSeen[who] = frame.c
    return { src = frame.s, instance = frame.i, msg = msg }
  end

  return B
end

return bus
