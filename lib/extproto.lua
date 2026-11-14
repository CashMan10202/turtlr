-- External protocol: how a player's device (pocket or turtle) talks to the two edge computers.
--
-- A device has two key pairs: one for signing (Ed25519) and one for key agreement (X25519).
-- INCOMING and OUTGOING each have their own key-agreement pair.
--
--   request  (device -> INCOMING): sealed with the secret shared by the device and INCOMING.
--            Inside: the encoded message and the device's signature over it.
--            INCOMING can read it, but cannot forge it: COMPUTE checks the signature again.
--   response (OUTGOING -> device): sealed with the secret shared by OUTGOING and the device.
--
-- Frame on the wire: codec{ v = 1, d = device id, c = counter, p = sealed bytes }
local codec = require("lib.codec")
local S = require("lib.schema")

local ext = {}

ext.MAX_FRAME = 8192

local frameSpec = S.map({ v = S.int(1, 1), d = S.int(1, 2 ^ 31), c = S.int(1, 2 ^ 53), p = S.bytes(ext.MAX_FRAME) })
local innerSpec = S.map({ m = S.bytes(ext.MAX_FRAME), s = S.bytes(64) })

-- Shared keys are slow to compute (elliptic-curve maths in Lua), so they are remembered.
local keyCache, cacheSize = {}, 0
local function sharedKey(crypto, dir, mySk, theirPk, devPk, edgePk)
  local id = dir .. mySk .. theirPk
  local key = keyCache[id]
  if not key then
    if cacheSize >= 256 then keyCache, cacheSize = {}, 0 end
    key = crypto.kdf("buildkit ext v1 " .. dir, crypto.exchange(mySk, theirPk) .. devPk .. edgePk)
    keyCache[id], cacheSize = key, cacheSize + 1
  end
  return key
end

local function aad(dir, devId, counter) return dir .. "|" .. devId .. "|" .. counter end
local function signed(devId, counter, raw) return "bk1|" .. devId .. "|" .. counter .. "|" .. raw end

-- A fresh set of device keys. The secret halves never leave the device.
function ext.newIdentity(crypto)
  local signSk, signPk = crypto.signKeypair()
  local kxSk, kxPk = crypto.kxKeypair()
  return { signSk = signSk, signPk = signPk, kxSk = kxSk, kxPk = kxPk }
end

-- Device side. dev = { id, signSk, signPk, kxSk, kxPk, inPk, outPk }.
function ext.sealRequest(crypto, dev, counter, msg)
  local raw = codec.encode(msg)
  local sig = crypto.sign(dev.signSk, dev.signPk, signed(dev.id, counter, raw))
  local key = sharedKey(crypto, "in", dev.kxSk, dev.inPk, dev.kxPk, dev.inPk)
  local sealed = crypto.seal(key, counter, codec.encode({ m = raw, s = sig }), aad("in", dev.id, counter))
  return codec.encode({ v = 1, d = dev.id, c = counter, p = sealed })
end

-- INCOMING side. lookup(devId) -> { id, signPk, kxPk, revoked } or nil.
-- Returns { dev, counter, raw, sig, msg, record } or nil plus the reason it was dropped.
function ext.openRequest(crypto, frame, lookup, inSk, inPk)
  local f = codec.decode(frame, { maxItems = 8 })
  if type(f) ~= "table" or not S.check(frameSpec, f) then return nil, "bad_frame" end
  local record = lookup(f.d)
  if not record then return nil, "unknown_device" end
  if record.revoked == 1 or record.revoked == true then return nil, "revoked" end
  local key = sharedKey(crypto, "in", inSk, record.kxPk, record.kxPk, inPk)
  local plain = crypto.open(key, f.c, f.p, aad("in", f.d, f.c))
  if not plain then return nil, "bad_auth" end
  local inner = codec.decode(plain, { maxItems = 4 })
  if type(inner) ~= "table" or not S.check(innerSpec, inner) then return nil, "bad_frame" end
  local msg = codec.decode(inner.m)
  if type(msg) ~= "table" then return nil, "bad_frame" end
  return { dev = f.d, counter = f.c, raw = inner.m, sig = inner.s, msg = msg, record = record }
end

-- COMPUTE side: check the device really signed this exact message with this counter.
function ext.verifyRequest(crypto, record, counter, raw, sig)
  if type(raw) ~= "string" or type(record) ~= "table" or type(counter) ~= "number" then return false end
  return crypto.verify(record.signPk, signed(record.id, counter, raw), sig)
end

-- OUTGOING side. record = { id, kxPk } of the device the reply is for.
function ext.sealResponse(crypto, outSk, outPk, record, counter, msg)
  local key = sharedKey(crypto, "out", outSk, record.kxPk, record.kxPk, outPk)
  local sealed = crypto.seal(key, counter, codec.encode(msg), aad("out", record.id, counter))
  return codec.encode({ v = 1, d = record.id, c = counter, p = sealed })
end

-- Device side. Returns { counter, msg } or nil.
function ext.openResponse(crypto, dev, frame)
  local f = codec.decode(frame, { maxItems = 8 })
  if type(f) ~= "table" or not S.check(frameSpec, f) or f.d ~= dev.id then return nil end
  local key = sharedKey(crypto, "out", dev.kxSk, dev.outPk, dev.kxPk, dev.outPk)
  local plain = crypto.open(key, f.c, f.p, aad("out", f.d, f.c))
  if not plain then return nil end
  local msg = codec.decode(plain)
  if type(msg) ~= "table" then return nil end
  return { counter = f.c, msg = msg }
end

return ext
