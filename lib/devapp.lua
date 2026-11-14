-- What a pocket or turtle runs in Phase 3: register at the owner's desk, then stay connected.
-- (The real pocket app and turtle program replace the "connected" part in later phases.)
local enroll = require("lib.enroll")
local identity = require("lib.identity")
local devclient = require("lib.devclient")
local lock = require("lib.lock")
local proto = require("lib.proto")

local devapp = {}

devapp.VERSION = "0.3.0"
local ID_PATH = "/bs/device.lua"

-- env: { fs, settings, crypto, modem, clock, pull, startTimer, show(lines), kind }
-- show(lines) displays a list of text lines (the caller decides how).
function devapp.enrol(env)
  local crypto, modem = env.crypto, env.modem
  local id = env.crypto and require("lib.extproto").newIdentity(crypto)
  local nonce = crypto.random(8)
  local code = enroll.code(crypto, id.signPk, id.kxPk, nonce)
  modem.open(proto.CH.ENROLL)
  env.show({ "Not registered yet.", "", "Take this to the owner's", "registration desk.", "",
    "Code:  " .. code:sub(1, 3) .. " " .. code:sub(4) })
  local frame = enroll.request(id, env.kind, nonce)
  while true do
    modem.transmit(proto.CH.ENROLL, proto.CH.ENROLL, frame)
    local timer = env.startTimer(3)
    while true do
      local ev, a, channel, _, payload = env.pull()
      if ev == "timer" and a == timer then break end
      if ev == "modem_message" and channel == proto.CH.ENROLL then
        local grant = enroll.openReply(crypto, id, nonce, payload)
        if grant then
          id.id, id.kind, id.player = grant.id, env.kind, grant.player
          id.inPk, id.outPk = grant.inPk, grant.outPk
          identity.save(env.fs, ID_PATH, id)
          modem.close(proto.CH.ENROLL)
          return id, enroll.checkNumber(crypto, grant, grant.regPk, id.signPk)
        end
      end
    end
  end
end

-- Runs forever (returns only when the owner unlocks the device).
function devapp.run(env)
  local id = identity.load(env.fs, ID_PATH)
  local check
  if not id then id, check = devapp.enrol(env) end
  local C = devclient.new({ crypto = env.crypto, modem = env.modem, identity = id, clock = env.clock,
    pull = env.pull, startTimer = env.startTimer })
  local status = "connecting..."
  while true do
    local started = env.clock()
    local res, err = C.request("hello", { client = devapp.VERSION, caps = env.caps or 0 })
    if res then
      status = ("connected (%d ms)"):format(env.clock() - started)
      -- lock only once the base has really answered: a device that cannot reach the base must
      -- stay open, because unlocking also goes through the base
      if not res.unlock and not lock.isLocked(env.fs) then lock.engage(env.fs, env.settings) end
      if res.unlock then
        lock.release(env.fs, env.settings)
        env.show({ "Unlocked by the owner.", "This device is open again." })
        return "unlocked"
      end
    else
      status = "no answer (" .. tostring(err) .. ")"
    end
    local lines = { "BuildKit " .. env.kind .. " #" .. id.id, "Owner: " .. id.player, "", "Server: " .. status }
    if res then lines[#lines + 1] = "Server version " .. res.server end
    if check then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Check number: " .. check
      lines[#lines + 1] = "(must match the desk screen)"
    end
    env.show(lines)
    local timer = env.startTimer(5)
    repeat local ev, a = env.pull() until ev == "timer" and a == timer
  end
end

return devapp
