-- COMPUTE program: the brain of the base. Phase 3: device registry and the "hello" request.
local node = require("lib.node")
local storeclient = require("lib.storeclient")
local registry = require("roles.compute.registry")
local dispatch = require("roles.compute.dispatch")

local VERSION = "0.3.0"

local N = node.start("compute")
local store = storeclient.new({ rpc = N.rpc, sleep = sleep })
local Reg = registry.new({ store = store, clock = N.clock })

local D = dispatch.new({
  crypto = N.crypto, registry = Reg, clock = N.clock, log = N.log,
  send = function(record, response)
    N.rpc.notify("outgoing", "res", { d = { id = record.id, kxPk = record.kxPk }, msg = response })
  end,
  handlers = {
    hello = function(ctx)
      local body = { server = VERSION, minClient = VERSION, time = ctx.now, state = "ok" }
      if ctx.dev.unlock == 1 then body.unlock = true end
      return body
    end,
  },
})

local function public(rec)
  return { id = rec.id, kind = rec.kind, player = rec.player, signPk = rec.signPk, kxPk = rec.kxPk,
    revoked = rec.revoked, unlock = rec.unlock }
end

local ADMIN = { register = true, monitor = true }

local handlers = {
  req = function(body, src)
    if src == "incoming" then D.onRequest(body) end
  end,
  dev_get = function(body, src)
    if src ~= "incoming" and not ADMIN[src] then return nil, "not_allowed" end
    local rec, err = Reg.get(body.id)
    if not rec then return nil, err or "not_found" end
    return public(rec)
  end,
  dev_add = function(body, src)
    if src ~= "register" then return nil, "not_allowed" end
    if (body.kind ~= "pocket" and body.kind ~= "worker") or type(body.player) ~= "string"
        or not body.player:find("^[A-Za-z0-9_]+$") or #body.player > 16
        or type(body.signPk) ~= "string" or #body.signPk ~= 32
        or type(body.kxPk) ~= "string" or #body.kxPk ~= 32 then
      return nil, "bad_request"
    end
    local id, err = Reg.add(body.kind, body.player, body.signPk, body.kxPk)
    if not id then return nil, err end
    N.log.info("registry", "device added", { id = id, kind = body.kind, player = body.player })
    return { id = id }
  end,
  dev_list = function(body, src)
    if not ADMIN[src] then return nil, "not_allowed" end
    local list, err = Reg.list(type(body.player) == "string" and body.player or nil)
    if not list then return nil, err end
    local out = {}
    for i = 1, math.min(#list, 100) do
      local r = list[i]
      out[i] = { id = r.id, kind = r.kind, player = r.player, revoked = r.revoked, unlock = r.unlock }
    end
    return { devices = out }
  end,
  dev_set = function(body, src)
    if not ADMIN[src] then return nil, "not_allowed" end
    local fields = {}
    if body.revoked == 0 or body.revoked == 1 then fields.revoked = body.revoked end
    if body.unlock == 0 or body.unlock == 1 then fields.unlock = body.unlock end
    local ok, err = Reg.update(body.id, fields)
    if not ok then return nil, err end
    N.rpc.notify("incoming", "dev_drop", { id = body.id })
    N.log.info("registry", "device changed", { id = body.id, revoked = fields.revoked, unlock = fields.unlock })
    return {}
  end,
  stats = function() return D.stats end,
}

print("COMPUTE running.")
parallel.waitForAny(N.rpc.pumpLoop, function() N.rpc.serveLoop(handlers) end)
