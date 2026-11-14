-- REGISTER desk logic: pairs new devices with players. Only works while the owner stands at the desk.
local enroll = require("lib.enroll")

local registrar = {}

local PENDING_MAX, PENDING_MS = 16, 120000

function registrar.new(opts)
  local crypto, rpc, clock, cfg = opts.crypto, opts.rpc, opts.clock, opts.cfg
  local pending = {}   -- code -> { req, at, dup }
  local approved = {}  -- code -> { frame, at }  (re-sent if the device asks again)
  local edge
  local Rg = {}

  local function expire()
    local now = clock()
    for code, p in pairs(pending) do
      if now - p.at > PENDING_MS then pending[code] = nil end
    end
    for code, a in pairs(approved) do
      if now - a.at > PENDING_MS then approved[code] = nil end
    end
  end

  -- Names of players standing at the desk (from the Player Detector).
  function Rg.players()
    local ok, list = pcall(opts.detector, cfg.detectRange)
    local names = {}
    if ok and type(list) == "table" then
      for _, p in ipairs(list) do
        local name = type(p) == "table" and p.name or p
        if type(name) == "string" then names[#names + 1] = name end
      end
    end
    table.sort(names)
    return names
  end

  function Rg.ownerPresent()
    for _, name in ipairs(Rg.players()) do
      if name == cfg.owner then return true end
    end
    return false
  end

  -- Feed every frame heard on the enrolment channel in here.
  function Rg.onFrame(frame)
    expire()
    local req = enroll.parseRequest(frame)
    if not req then return end
    local code = enroll.code(crypto, req.signPk, req.kxPk, req.n)
    if approved[code] then
      if approved[code].signPk == req.signPk then opts.transmit(approved[code].frame) end
      return
    end
    local p = pending[code]
    if p then
      -- same code from different keys: someone is trying to slip in. Refuse both.
      if p.req.signPk ~= req.signPk or p.req.kxPk ~= req.kxPk then p.dup = true end
      p.at = clock()
      return
    end
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    if n >= PENDING_MAX then return end
    pending[code] = { req = req, at = clock() }
  end

  -- Devices currently asking to be registered: { { code, kind, age } }.
  function Rg.pending()
    expire()
    local out = {}
    for code, p in pairs(pending) do
      out[#out + 1] = { code = code, kind = p.req.kind, age = math.floor((clock() - p.at) / 1000) }
    end
    table.sort(out, function(a, b) return a.code < b.code end)
    return out
  end

  local function edgeKeys()
    if edge then return edge end
    local i, e1 = rpc.call("incoming", "pubkey", {}, 5)
    if not i then return nil, "incoming: " .. tostring(e1) end
    local o, e2 = rpc.call("outgoing", "pubkey", {}, 5)
    if not o then return nil, "outgoing: " .. tostring(e2) end
    edge = { inPk = i.pk, outPk = o.pk }
    return edge
  end

  -- Register the device showing `code` for `player`. Returns { id, check } or nil plus a reason.
  function Rg.approve(code, player)
    expire()
    if not Rg.ownerPresent() then return nil, "owner_absent" end
    code = tostring(code):gsub("%s", "")
    local p = pending[code]
    if not p then return nil, "no_such_code" end
    if p.dup then pending[code] = nil; return nil, "ambiguous" end
    local here = false
    for _, name in ipairs(Rg.players()) do here = here or name == player end
    if not here then return nil, "player_absent" end
    local keys, err = edgeKeys()
    if not keys then return nil, err end
    local res, e = rpc.call("compute", "dev_add",
      { kind = p.req.kind, player = player, signPk = p.req.signPk, kxPk = p.req.kxPk }, 40)
    if not res then return nil, e end
    local grant = { id = res.id, inPk = keys.inPk, outPk = keys.outPk, player = player }
    local frame = enroll.reply(crypto, opts.regSk, opts.regPk, p.req, grant)
    pending[code] = nil
    approved[code] = { frame = frame, at = clock(), signPk = p.req.signPk }
    opts.transmit(frame)
    return { id = res.id, kind = p.req.kind,
      check = enroll.checkNumber(crypto, grant, opts.regPk, p.req.signPk) }
  end

  local function admin(method, body)
    if not Rg.ownerPresent() then return nil, "owner_absent" end
    return rpc.call("compute", method, body, 40)
  end

  function Rg.list(player) return admin("dev_list", { player = player }) end
  function Rg.revoke(id) return admin("dev_set", { id = id, revoked = 1 }) end
  function Rg.restore(id) return admin("dev_set", { id = id, revoked = 0 }) end
  function Rg.unlock(id, on) return admin("dev_set", { id = id, unlock = on and 1 or 0 }) end

  return Rg
end

return registrar
