local t = require("test.t")
local shim = require("test.cc_shim")
local crypto = require("lib.crypto")
local ext = require("lib.extproto")
local enroll = require("lib.enroll")
local identity = require("lib.identity")
local lock = require("lib.lock")
if not crypto.ready() then crypto.init(("enroll-test-seed"):rep(3)) end

local T = {}

local function setup()
  local id = ext.newIdentity(crypto)
  local nonce = crypto.random(8)
  local regSk, regPk = crypto.kxKeypair()
  local inPk, outPk = select(2, crypto.kxKeypair()), select(2, crypto.kxKeypair())
  return id, nonce, regSk, regPk, { id = 12, inPk = inPk, outPk = outPk, player = "Steve" }
end

function T.full_exchange()
  local id, nonce, regSk, regPk, grant = setup()
  local frame = enroll.request(id, "pocket", nonce)
  t.ok(not frame:find(id.signSk, 1, true) and not frame:find(id.kxSk, 1, true), "secret keys must never be sent")
  local req = assert(enroll.parseRequest(frame))
  t.eq(req.kind, "pocket")
  local code = enroll.code(crypto, req.signPk, req.kxPk, req.n)
  t.ok(code:find("^%d%d%d%d%d%d$"))
  t.eq(code, enroll.code(crypto, id.signPk, id.kxPk, nonce))
  local reply = enroll.reply(crypto, regSk, regPk, req, grant)
  local got = assert(enroll.openReply(crypto, id, nonce, reply))
  t.eq(got.id, 12); t.eq(got.player, "Steve"); t.eq(got.inPk, grant.inPk); t.eq(got.outPk, grant.outPk)
  local a = enroll.checkNumber(crypto, grant, regPk, req.signPk)
  t.eq(a, enroll.checkNumber(crypto, got, got.regPk, id.signPk))
  t.ok(a:find("^%d%d%d%d$"))
end

function T.reply_for_another_device_or_request_is_ignored()
  local id, nonce, regSk, regPk, grant = setup()
  local req = enroll.parseRequest(enroll.request(id, "pocket", nonce))
  local reply = enroll.reply(crypto, regSk, regPk, req, grant)
  local other = ext.newIdentity(crypto)
  t.eq(enroll.openReply(crypto, other, nonce, reply), nil)
  t.eq(enroll.openReply(crypto, id, crypto.random(8), reply), nil)
  t.eq(enroll.openReply(crypto, id, nonce, "junk"), nil)
  t.eq(enroll.openReply(crypto, id, nonce, enroll.request(id, "pocket", nonce)), nil)
end

function T.swapped_edge_keys_change_the_check_number()
  -- someone answering in REGISTER's place with their own keys cannot produce the same check number
  local id, nonce, regSk, regPk, grant = setup()
  local req = enroll.parseRequest(enroll.request(id, "pocket", nonce))
  local evilSk, evilPk = crypto.kxKeypair()
  local evilGrant = { id = 12, inPk = evilPk, outPk = evilPk, player = "Steve" }
  local got = enroll.openReply(crypto, id, nonce, enroll.reply(crypto, evilSk, evilPk, req, evilGrant))
  t.ok(got, "the device cannot tell by itself...")
  t.ok(enroll.checkNumber(crypto, got, got.regPk, id.signPk) ~= enroll.checkNumber(crypto, grant, regPk, id.signPk),
    "...but the check numbers differ")
end

function T.bad_requests_are_rejected()
  for _, frame in ipairs({ "", "junk", 5 }) do t.eq(enroll.parseRequest(frame), nil) end
  local codec = require("lib.codec")
  t.eq(enroll.parseRequest(codec.encode({ t = "eq", kind = "admin", signPk = ("a"):rep(32), kxPk = ("b"):rep(32),
    n = ("c"):rep(8) })), nil)
  t.eq(enroll.parseRequest(codec.encode({ t = "eq", kind = "pocket", signPk = "short", kxPk = ("b"):rep(32),
    n = ("c"):rep(8) })), nil)
end

function T.identity_file_round_trip_and_damage()
  local e = shim.new()
  local id = ext.newIdentity(crypto)
  id.id, id.kind, id.player = 12, "worker", "Steve"
  id.inPk, id.outPk = select(2, crypto.kxKeypair()), select(2, crypto.kxKeypair())
  identity.save(e.fs, "/bs/device.lua", id)
  t.eq(identity.load(e.fs, "/bs/device.lua"), id)
  t.ok(not e.read("/bs/device.lua"):find("[^\32-\126\n]"))
  t.eq(identity.load(e.fs, "/nope.lua"), nil)
  e.write("/bs/device.lua", "return { id = 1 }")
  t.eq(identity.load(e.fs, "/bs/device.lua"), nil)
  e.write("/bs/device.lua", "os.reboot()")
  t.eq(identity.load(e.fs, "/bs/device.lua"), nil)
end

function T.lock_engage_and_release()
  local e = shim.new()
  local set = {}
  local settings = { set = function(k, v) set[k] = v end, save = function() set.saved = (set.saved or 0) + 1 end }
  t.eq(lock.isLocked(e.fs), false)
  lock.engage(e.fs, settings)
  t.eq(lock.isLocked(e.fs), true)
  t.eq(set["shell.allow_disk_startup"], false)
  t.eq(set.saved, 1)
  lock.release(e.fs, settings)
  t.eq(lock.isLocked(e.fs), false)
  t.eq(set["shell.allow_disk_startup"], true)
end

return T
