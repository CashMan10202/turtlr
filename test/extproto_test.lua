local t = require("test.t")
local crypto = require("lib.crypto")
local ext = require("lib.extproto")
if not crypto.ready() then crypto.init(("ext-test-seed"):rep(4)) end

local T = {}

-- one device and the two edge computers, as registration would set them up
local function world()
  local w = {}
  w.dev = ext.newIdentity(crypto)           -- { signSk, signPk, kxSk, kxPk }
  w.inSk, w.inPk = crypto.kxKeypair()
  w.outSk, w.outPk = crypto.kxKeypair()
  w.dev.id, w.dev.inPk, w.dev.outPk = 7, w.inPk, w.outPk
  w.record = { id = 7, signPk = w.dev.signPk, kxPk = w.dev.kxPk }
  w.lookup = function(id) if id == 7 then return w.record end end
  return w
end

local msg = { v = 1, t = "hello", id = 3, ts = 1700000000000, b = { client = "0.3.0", caps = 2 } }

function T.crypto_sign_and_exchange()
  local sk, pk = crypto.signKeypair()
  local sig = crypto.sign(sk, pk, "msg")
  t.eq(#sig, 64)
  t.ok(crypto.verify(pk, "msg", sig))
  t.ok(not crypto.verify(pk, "msg2", sig))
  t.ok(not crypto.verify(pk, "msg", sig:sub(1, 63) .. "x"))
  t.ok(not crypto.verify("short", "msg", sig))
  t.ok(not crypto.verify(pk, "msg", "short"))
  local a, A = crypto.kxKeypair()
  local b, B = crypto.kxKeypair()
  t.eq(crypto.exchange(a, B), crypto.exchange(b, A))
  t.eq(#A, 32)
end

function T.request_round_trip()
  local w = world()
  local frame = ext.sealRequest(crypto, w.dev, 1000, msg)
  t.ok(not frame:find("hello", 1, true), "request must not be readable on the wire")
  local got = assert(ext.openRequest(crypto, frame, w.lookup, w.inSk, w.inPk))
  t.eq(got.dev, 7); t.eq(got.counter, 1000)
  t.eq(got.msg, msg)
  -- COMPUTE checks the signature again from what INCOMING forwarded
  t.ok(ext.verifyRequest(crypto, w.record, got.counter, got.raw, got.sig))
end

function T.forged_forward_fails_at_compute()
  -- a compromised INCOMING cannot invent or alter a request: the signature will not match
  local w = world()
  local got = ext.openRequest(crypto, ext.sealRequest(crypto, w.dev, 1000, msg), w.lookup, w.inSk, w.inPk)
  t.ok(not ext.verifyRequest(crypto, w.record, got.counter + 1, got.raw, got.sig))
  t.ok(not ext.verifyRequest(crypto, w.record, got.counter, got.raw .. "x", got.sig))
  local other = ext.newIdentity(crypto)
  t.ok(not ext.verifyRequest(crypto, { id = 7, signPk = other.signPk }, got.counter, got.raw, got.sig))
  t.ok(not ext.verifyRequest(crypto, { id = 8, signPk = w.dev.signPk }, got.counter, got.raw, got.sig))
  t.ok(not ext.verifyRequest(crypto, w.record, got.counter, 5, got.sig))
end

function T.request_rejections()
  local w = world()
  local frame = ext.sealRequest(crypto, w.dev, 1000, msg)
  local function why(f, lookup, sk, pk)
    local got, reason = ext.openRequest(crypto, f, lookup or w.lookup, sk or w.inSk, pk or w.inPk)
    t.eq(got, nil)
    return reason
  end
  t.eq(why(frame, function() return nil end), "unknown_device")
  w.record.revoked = 1
  t.eq(why(frame), "revoked")
  w.record.revoked = 0
  t.eq(why(frame, nil, w.outSk, w.outPk), "bad_auth") -- sent to the wrong edge computer
  t.eq(why("garbage"), "bad_frame")
  t.eq(why(""), "bad_frame")
  t.eq(why(5), "bad_frame")
  -- a different device cannot use this device's id
  local thief = ext.newIdentity(crypto)
  thief.id, thief.inPk, thief.outPk = 7, w.inPk, w.outPk
  t.eq(why(ext.sealRequest(crypto, thief, 1000, msg)), "bad_auth")
  for i = 1, #frame do
    local bad = frame:sub(1, i - 1) .. string.char((frame:byte(i) + 1) % 256) .. frame:sub(i + 1)
    local ok, got = pcall(ext.openRequest, crypto, bad, w.lookup, w.inSk, w.inPk)
    t.ok(ok and got == nil, "tampered byte " .. i .. " accepted")
  end
end

function T.response_round_trip_and_rejections()
  local w = world()
  local res = { v = 1, t = "hello", re = 3, ok = true, b = { server = "0.3.0", minClient = "0.3.0",
    time = 1700000000000, state = "ok" } }
  local frame = ext.sealResponse(crypto, w.outSk, w.outPk, w.record, 2000, res)
  t.ok(not frame:find("minClient", 1, true))
  local got = assert(ext.openResponse(crypto, w.dev, frame))
  t.eq(got.counter, 2000); t.eq(got.msg, res)
  -- not for this device
  local other = ext.newIdentity(crypto); other.id, other.inPk, other.outPk = 8, w.inPk, w.outPk
  t.eq(ext.openResponse(crypto, other, frame), nil)
  -- a response forged by someone without OUTGOING's key
  local fakeSk, fakePk = crypto.kxKeypair()
  t.eq(ext.openResponse(crypto, w.dev, ext.sealResponse(crypto, fakeSk, fakePk, w.record, 2000, res)), nil)
  -- a request frame replayed back at the device is not a response
  t.eq(ext.openResponse(crypto, w.dev, ext.sealRequest(crypto, w.dev, 1000, msg)), nil)
  t.eq(ext.openResponse(crypto, w.dev, "junk"), nil)
end

function T.frames_stay_small()
  local w = world()
  t.ok(#ext.sealRequest(crypto, w.dev, 1700000000000 * 4096, msg) < 250)
end

return T
