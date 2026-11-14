-- Device registry: which pockets and turtles exist, whose they are, and their public keys.
-- Kept in storage (namespace "players", keys "dev-00000001" ...), with a copy in memory.
local registry = {}

local function key(id) return ("dev-%08d"):format(id) end

function registry.new(opts)
  local store, clock = opts.store, opts.clock
  local cache = {}
  local Reg = {}

  -- Returns the record or nil. Records: { id, kind, player, signPk, kxPk, revoked, unlock, created }.
  function Reg.get(id)
    if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then return nil end
    if cache[id] == nil then
      local rec, err = store.getTable("players", key(id))
      if not rec and err ~= "not_found" then return nil, err end
      cache[id] = rec or false
    end
    return cache[id] or nil
  end

  local function save(rec)
    local ok, err = store.putTable("players", key(rec.id), rec)
    if not ok then cache[rec.id] = nil; return nil, err end
    cache[rec.id] = rec
    return true
  end

  -- Register a new device. Returns its id.
  function Reg.add(kind, player, signPk, kxPk)
    local counter = store.getTable("config", "dev-next") or { n = 1 }
    local id = counter.n
    -- never reuse an id, even if the counter was lost
    while Reg.get(id) do id = id + 1 end
    local ok, err = store.putTable("config", "dev-next", { n = id + 1 })
    if not ok then return nil, err end
    ok, err = save({ id = id, kind = kind, player = player, signPk = signPk, kxPk = kxPk,
      revoked = 0, unlock = 0, created = clock() })
    if not ok then return nil, err end
    return id
  end

  function Reg.update(id, fields)
    local rec, err = Reg.get(id)
    if not rec then return nil, err or "not_found" end
    local copy = {}
    for k, v in pairs(rec) do copy[k] = v end
    for k, v in pairs(fields) do copy[k] = v end
    return save(copy)
  end

  -- All devices (optionally only one player's). Reads storage, so not for hot paths.
  function Reg.list(player)
    local out, after = {}, nil
    while true do
      local keys, more = store.list("players", "dev-", after, 200)
      if not keys then return nil, more end
      for _, k in ipairs(keys) do
        local rec = Reg.get(tonumber(k:sub(5)))
        if rec and (not player or rec.player == player) then out[#out + 1] = rec end
        after = k
      end
      if not more then break end
    end
    return out
  end

  return Reg
end

return registry
