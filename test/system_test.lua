-- Whole-system test: the real storage, compute, incoming and outgoing programs running on simulated
-- computers, a registration desk, and a pocket that registers and then talks to the base.
local t = require("test.t")
local simlib = require("test.sim")
local shim = require("test.cc_shim")
local boot = require("test.boot")
local fake_nbt = require("test.fake_nbt")
local crypto = require("lib.crypto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local keys_core = require("install.keys_core")
local registrar = require("roles.register.registrar")
local devapp = require("lib.devapp")
local lock = require("lib.lock")
if not crypto.ready() then crypto.init(("system-test-seed"):rep(3)) end

local T = {}

local n = 0
local allKeys = keys_core.generate(function(len) n = n + 1; return string.char(n):rep(len) end, keys_core.ROLES)

local function world()
  local w = { sim = simlib.new(), atDesk = { "Cashman", "Steve" } }
  local sim = w.sim
  local nbt = {}
  for i = 1, 3 do nbt["nbt_storage_" .. i] = { "nbt_storage", (fake_nbt.new({ style = "save", reader = "load", quiet = true })) } end
  w.storage = boot.computer(sim, { name = "storage", role = "storage", keys = allKeys.storage,
    config = "return { id = 1 }", peripherals = nbt })
  w.compute = boot.computer(sim, { name = "compute", role = "compute", keys = allKeys.compute, config = "return {}" })
  w.incoming = boot.computer(sim, { name = "incoming", role = "incoming", keys = allKeys.incoming,
    config = "return {}", secondModemSide = "back" })
  w.outgoing = boot.computer(sim, { name = "outgoing", role = "outgoing", keys = allKeys.outgoing,
    config = "return {}", secondModemSide = "back" })

  -- registration desk (logic only; its menu is typed by hand in-game)
  local rn = sim.node("register")
  local b = bus.new({ modem = rn.modem, channel = 4210, role = "register", instance = 1, keys = allKeys.register,
    crypto = crypto, clock = rn.clock })
  local r = rpc.new({ bus = b, pull = rn.pull, startTimer = rn.startTimer, queueEvent = rn.queueEvent, clock = rn.clock })
  rn.spawn(r.pumpLoop)
  rn.modem.open(4203)
  local regSk, regPk = crypto.kxKeypair()
  w.Rg = registrar.new({ crypto = crypto, rpc = r, clock = rn.clock, regSk = regSk, regPk = regPk,
    cfg = { owner = "Cashman", detectRange = 3 },
    detector = function() return w.atDesk end,
    transmit = function(frame) rn.modem.transmit(4203, 4203, frame) end })
  rn.spawn(function()
    while true do
      local _, _, ch, _, payload = rn.pull("modem_message")
      if ch == 4203 then w.Rg.onFrame(payload) end
    end
  end)
  w.rpc, w.rn = r, rn
  function w.atRegister(fn)
    local out
    rn.spawn(function() out = { fn() } end)
    t.ok(sim.run(function() return out ~= nil end), "simulation went idle")
    return table.unpack(out)
  end

  -- a device (pocket or turtle)
  function w.device(name, kind, e)
    local node = sim.node(name)
    local d = { node = node, e = e or shim.new(), screen = {}, settings = {} }
    local settings = { set = function(k, v) d.settings[k] = v end, save = function() end }
    node.spawn(function()
      d.result = devapp.run({ fs = d.e.fs, settings = settings, crypto = crypto, modem = node.modem, kind = kind,
        clock = node.clock, pull = node.pull, startTimer = node.startTimer,
        show = function(lines) d.screen = lines end })
    end)
    function d.text() return table.concat(d.screen, "\n") end
    function d.code() return (d.text():match("Code:%s+(%d%d%d %d%d%d)") or ""):gsub(" ", "") end
    return d
  end
  sim.runFor(8000) -- let every program start and storage become primary
  function w.waitFor(cond, what)
    t.ok(sim.run(cond, 2000000), "never happened: " .. what)
  end
  return w
end

local function registered(w, name, kind, player)
  local d = w.device(name, kind or "pocket")
  w.waitFor(function() return d.code() ~= "" end, "device shows a code")
  w.waitFor(function()
    for _, p in ipairs(w.Rg.pending()) do if p.code == d.code() then return true end end
  end, "the desk hears the device")
  local res, err = w.atRegister(function() return w.Rg.approve(d.code(), player or "Steve") end)
  t.ok(res, "approve failed: " .. tostring(err))
  w.waitFor(function() return d.text():find("connected", 1, true) end, "device connects")
  return d, res
end

function T.all_programs_start_cleanly()
  local w = world()
  w.sim.runFor(8000)
  for _, name in ipairs({ "storage", "compute", "incoming", "outgoing" }) do
    t.eq(w[name].failure(), nil, name)
    t.ok(table.concat(w[name].printed, " "):lower():find("running", 1, true), name .. " did not report running")
  end
end

function T.pocket_registers_then_talks_to_the_base()
  local w = world()
  local d, res = registered(w, "pocket1", "pocket", "Steve")
  t.eq(res.kind, "pocket")
  local screen = d.text()
  t.ok(screen:find("Owner: Steve", 1, true), screen)
  t.ok(screen:find("Check number: " .. res.check, 1, true), "check numbers differ:\n" .. screen)
  t.ok(screen:find("Server version 0.3.0", 1, true), screen)
  -- the device locked itself and switched off booting from floppies
  t.eq(lock.isLocked(d.e.fs), true)
  t.eq(d.settings["shell.allow_disk_startup"], false)
  -- the registry survives in storage
  local list = w.atRegister(function() return w.Rg.list("Steve") end)
  t.eq(#list.devices, 1)
  t.eq(list.devices[1].id, res.id)
end

function T.nothing_secret_crosses_the_air()
  local w = world()
  local seen = {}
  w.sim.net.tap(function(_, _, payload) seen[#seen + 1] = tostring(payload) end)
  local d = registered(w, "pocket1")
  local id = require("lib.identity").load(d.e.fs, "/bs/device.lua")
  local air = table.concat(seen)
  for _, secret in ipairs({ id.signSk, id.kxSk, allKeys.compute.storage, allKeys.incoming.compute }) do
    t.ok(not air:find(secret, 1, true), "a secret key was transmitted")
  end
  t.ok(not air:find("Steve", 1, true), "the player's name was readable on the air")
  t.ok(not air:find("minClient", 1, true), "a reply was readable on the air")
end

function T.registration_needs_the_owner_and_the_player_at_the_desk()
  local w = world()
  local d = w.device("pocket1", "pocket")
  w.waitFor(function() return d.code() ~= "" and #w.Rg.pending() > 0 end, "code")
  w.atDesk = { "Steve" }
  t.eq({ w.atRegister(function() return w.Rg.approve(d.code(), "Steve") end) }, { nil, "owner_absent" })
  w.atDesk = { "Cashman" }
  t.eq({ w.atRegister(function() return w.Rg.approve(d.code(), "Steve") end) }, { nil, "player_absent" })
  t.eq({ w.atRegister(function() return w.Rg.approve("000000", "Cashman") end) }, { nil, "no_such_code" })
  t.eq(lock.isLocked(d.e.fs), false)
  w.atDesk = { "Cashman", "Steve" }
  t.ok(w.atRegister(function() return w.Rg.approve(d.code(), "Steve") end))
end

function T.revoked_device_is_cut_off_and_restore_brings_it_back()
  local w = world()
  local d, res = registered(w, "pocket1")
  t.ok(w.atRegister(function() return w.Rg.revoke(res.id) end))
  w.waitFor(function() return d.text():find("no answer", 1, true) end, "revoked device loses contact")
  local stats = w.atRegister(function() return w.rpc.call("incoming", "stats", {}) end)
  t.ok((stats.revoked or 0) >= 1)
  t.ok(w.atRegister(function() return w.Rg.restore(res.id) end))
  w.waitFor(function() return d.text():find("connected", 1, true) end, "restored device reconnects")
end

function T.owner_can_unlock_a_device()
  local w = world()
  local d, res = registered(w, "pocket1")
  t.ok(w.atRegister(function() return w.Rg.unlock(res.id, true) end))
  w.waitFor(function() return d.result == "unlocked" end, "device unlocks")
  t.eq(lock.isLocked(d.e.fs), false)
  t.eq(d.settings["shell.allow_disk_startup"], true)
end

function T.device_keeps_its_registration_across_a_reboot()
  local w = world()
  local d, res = registered(w, "pocket1")
  d.node.kill()
  local again = w.device("pocket1b", "pocket", d.e) -- same disk, fresh start
  w.waitFor(function() return again.text():find("connected", 1, true) end, "reconnects after reboot")
  t.ok(again.text():find("#" .. res.id, 1, true))
  t.eq(again.code(), "")
end

function T.two_devices_and_a_turtle_have_separate_identities()
  local w = world()
  local _, a = registered(w, "pocket1", "pocket", "Steve")
  local _, b = registered(w, "turtle1", "worker", "Steve")
  local _, c = registered(w, "pocket2", "pocket", "Cashman")
  t.ok(a.id ~= b.id and b.id ~= c.id)
  t.eq(b.kind, "worker")
  t.eq(#w.atRegister(function() return w.Rg.list("Steve") end).devices, 2)
  t.eq(#w.atRegister(function() return w.Rg.list() end).devices, 3)
end

function T.replayed_and_forged_traffic_gets_nowhere()
  local w = world()
  local captured = {}
  local recording = true
  w.sim.net.tap(function(_, ch, payload) if recording and ch == 4201 then captured[#captured + 1] = payload end end)
  registered(w, "pocket1")
  recording = false
  t.ok(#captured >= 1)
  local before = w.atRegister(function() return w.rpc.call("compute", "stats", {}) end)
  -- an attacker with an ender modem replays recorded requests and sends junk
  local attacker = w.sim.node("attacker")
  local recorded = { table.unpack(captured) } -- fixed copy: the tap also sees what the attacker sends
  captured = recorded
  for _, frame in ipairs(recorded) do attacker.modem.transmit(4201, 4202, frame) end
  for i = 1, 30 do attacker.modem.transmit(4201, 4202, ("junk%d"):format(i):rep(i)) end
  attacker.modem.transmit(4201, 4202, ("x"):rep(20000))
  attacker.modem.transmit(4201, 4202, { table = "payload" })
  w.sim.runFor(3000)
  local gate = w.atRegister(function() return w.rpc.call("incoming", "stats", {}) end)
  t.ok((gate.replay or 0) >= #captured, "replays not detected")
  t.ok((gate.bad_frame or 0) >= 30)
  t.ok((gate.too_big or 0) >= 1)
  local after = w.atRegister(function() return w.rpc.call("compute", "stats", {}) end)
  -- only the pocket's own periodic hellos may have been added in the meantime
  t.ok(after.ok - before.ok <= 2, "forged traffic reached COMPUTE")
  t.eq(after.errors, 0)
  for _, name in ipairs({ "storage", "compute", "incoming", "outgoing" }) do t.eq(w[name].failure(), nil, name) end
end

function T.a_stranger_cannot_use_the_internal_admin_calls()
  local w = world()
  w.sim.runFor(8000)
  -- INGEST has valid bus keys but is not allowed to manage devices
  local ing = w.sim.node("ingest")
  local b = bus.new({ modem = ing.modem, channel = 4210, role = "ingest", instance = 1, keys = allKeys.ingest,
    crypto = crypto, clock = ing.clock })
  local r = rpc.new({ bus = b, pull = ing.pull, startTimer = ing.startTimer, queueEvent = ing.queueEvent, clock = ing.clock })
  ing.spawn(r.pumpLoop)
  local out
  ing.spawn(function()
    out = { { r.call("compute", "dev_add", { kind = "pocket", player = "Evil", signPk = ("a"):rep(32), kxPk = ("b"):rep(32) }) },
      { r.call("compute", "dev_list", {}) }, { r.call("compute", "dev_set", { id = 1, revoked = 1 }) },
      { r.call("outgoing", "res", { d = { id = 1, kxPk = ("b"):rep(32) }, msg = {} }) } }
  end)
  w.sim.run(function() return out ~= nil end)
  for i = 1, 3 do t.eq(out[i], { nil, "not_allowed" }) end
  t.eq(out[4], { nil, "not_allowed" })
end

return T
