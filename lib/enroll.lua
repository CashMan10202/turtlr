-- Registration ("enrolment") of a new pocket or turtle at the owner's desk.
--
--  1. The device makes its own keys and broadcasts its PUBLIC keys on the enrolment channel.
--     It shows a 6-digit code: a fingerprint of those keys.
--  2. The owner types that code on the REGISTER computer and picks the player.
--  3. REGISTER records the device and replies (sealed for that device) with its id and the
--     two edge computers' public keys.
--  4. Both screens show the same 4-digit check number. If they differ, someone interfered.
--
-- The device's secret keys never leave the device.
local codec = require("lib.codec")
local S = require("lib.schema")

local enroll = {}

local reqSpec = S.map({ t = S.enum({ "eq" }), kind = S.enum({ "pocket", "worker" }),
  signPk = S.bytes(32), kxPk = S.bytes(32), n = S.bytes(8) })
local replySpec = S.map({ t = S.enum({ "er" }), n = S.bytes(8), regPk = S.bytes(32), p = S.bytes(512) })
local grantSpec = S.map({ id = S.int(1, 2 ^ 31), inPk = S.bytes(32), outPk = S.bytes(32), player = S.str(16) })

local function digits(crypto, data, count)
  local h, n = crypto.hash(data), 0
  for i = 1, 6 do n = n * 256 + h:byte(i) end
  return ("%0" .. count .. "d"):format(n % 10 ^ count)
end

-- Device: the broadcast frame. identity = { signPk, kxPk }, nonce = 8 random bytes.
function enroll.request(identity, kind, nonce)
  return codec.encode({ t = "eq", kind = kind, signPk = identity.signPk, kxPk = identity.kxPk, n = nonce })
end

-- The 6-digit code both sides compute from the device's public keys.
function enroll.code(crypto, signPk, kxPk, nonce)
  return digits(crypto, "bk enroll code|" .. signPk .. kxPk .. nonce, 6)
end

-- REGISTER: returns { kind, signPk, kxPk, n } or nil.
function enroll.parseRequest(frame)
  local req = codec.decode(frame, { maxItems = 8 })
  if type(req) ~= "table" or not S.check(reqSpec, req) then return nil end
  if #req.signPk ~= 32 or #req.kxPk ~= 32 or #req.n ~= 8 then return nil end
  return req
end

local function replyKey(crypto, mySk, theirPk, nonce)
  return crypto.kdf("buildkit enroll v1", crypto.exchange(mySk, theirPk) .. nonce)
end

-- REGISTER: the sealed answer. grant = { id, inPk, outPk, player }.
function enroll.reply(crypto, regSk, regPk, req, grant)
  local sealed = crypto.seal(replyKey(crypto, regSk, req.kxPk, req.n), 1, codec.encode(grant), req.n)
  return codec.encode({ t = "er", n = req.n, regPk = regPk, p = sealed })
end

-- Device: returns the grant, or nil if the frame is not a valid answer to our request.
function enroll.openReply(crypto, identity, nonce, frame)
  local rep = codec.decode(frame, { maxItems = 8 })
  if type(rep) ~= "table" or not S.check(replySpec, rep) or rep.n ~= nonce or #rep.regPk ~= 32 then return nil end
  local plain = crypto.open(replyKey(crypto, identity.kxSk, rep.regPk, nonce), 1, rep.p, nonce)
  if not plain then return nil end
  local grant = codec.decode(plain, { maxItems = 8 })
  if type(grant) ~= "table" or not S.check(grantSpec, grant) or #grant.inPk ~= 32 or #grant.outPk ~= 32 then
    return nil
  end
  grant.regPk = rep.regPk
  return grant
end

-- The 4-digit number shown on both screens at the end.
function enroll.checkNumber(crypto, grant, regPk, signPk)
  return digits(crypto, "bk enroll check|" .. grant.id .. "|" .. grant.inPk .. grant.outPk .. regPk .. signPk, 4)
end

return enroll
