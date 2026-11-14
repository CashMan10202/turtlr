-- Storage engine: a replicated key/value store spread over many NBT Storage blocks ("devices").
--
-- How it stays safe:
--  * A value is cut into shards. Each shard is written as a "cell" to `replicas` different devices.
--  * Every cell describes itself (key, version, part number, hash). The index in memory can
--    therefore always be rebuilt by scanning the devices; nothing else needs to survive a crash.
--  * A new version is written completely, and read back, before the old one is removed. After a
--    power cut, rebuild() keeps the highest version that is complete and removes the rest.
--  * Deleting first writes a small "tombstone" cell with a higher version, so a half-finished
--    delete can never bring the old value back.
--
-- The engine is not re-entrant: run all operations from one coroutine.
local base64 = require("lib.base64")

local engine = {}

local NAMESPACES = { players = true, jobs = true, schematics = true, recipes = true, library = true,
  surveys = true, logs = true, config = true }
local MAX_VALUE = 4194304

-- Cell text: "<ns/key>|<ver>|<i>|<n>|<size>|<hash>|<flag>\n<base64 data>"
local function makeCell(k, ver, i, n, size, hash, flag, data)
  return ("%s|%d|%d|%d|%d|%s|%s\n%s"):format(k, ver, i, n, size, hash, flag, data)
end

local function parseHeader(cell)
  local nl = cell:find("\n", 1, true)
  if not nl then return nil end
  local k, ver, i, n, size, hash, flag = cell:sub(1, nl - 1):match(
    "^([a-z]+/[A-Za-z0-9_.:-]+)|(%d+)|(%d+)|(%d+)|(%d+)|([0-9a-f-]+)|([dx])$")
  if not k then return nil end
  return { k = k, ver = tonumber(ver), i = tonumber(i), n = tonumber(n), size = tonumber(size),
    hash = hash, flag = flag }, nl
end

function engine.new(opts)
  local crypto = opts.crypto
  local replicas = opts.replicas or 2
  local shardBytes = opts.shardBytes or 200000
  local deviceMax = opts.deviceMaxBytes or 1000000
  local yield = opts.yield or function() end

  local devices = {}  -- name -> D
  local order = {}    -- device names, sorted
  local dir = {}      -- name -> { [cellId] = meta } (meta has .bytes)
  local used = {}     -- name -> bytes in use
  local devOk = {}    -- name -> false when the last load failed
  local byKey = {}    -- k -> { [name .. "/" .. cellId] = { dev = name, id = cellId, meta = meta } }
  local index = {}    -- k -> { ver, n, size, shards = { [i] = { hash, devs = { name... } } } }
  local stats = { lost = 0 }
  local locked = false

  local E = {}

  local function addDevice(D)
    devices[D.name] = D
    order[#order + 1] = D.name
    table.sort(order)
    dir[D.name], used[D.name], devOk[D.name] = {}, 0, true
  end
  for _, D in ipairs(opts.devices or {}) do addDevice(D) end

  local function cellId(k, ver, i)
    return "c" .. crypto.hashHex(k .. "|" .. ver .. "|" .. i):sub(1, 16)
  end

  local function checkName(ns, key)
    if type(ns) ~= "string" or not NAMESPACES[ns] then return nil end
    if type(key) ~= "string" or #key < 1 or #key > 96 or key:find("[^A-Za-z0-9_.:-]") then return nil end
    return ns .. "/" .. key
  end

  -- Replace what we know about one device with what was just read from / written to it.
  -- Returns the ids of entries that are not valid cells.
  local function refresh(name, cells)
    for id in pairs(dir[name]) do
      local set = byKey[dir[name][id].k]
      if set then
        set[name .. "/" .. id] = nil
        if next(set) == nil then byKey[dir[name][id].k] = nil end
      end
    end
    local metas, total, junk = {}, 0, {}
    for id, cell in pairs(cells) do
      local meta = parseHeader(cell)
      if meta and id == cellId(meta.k, meta.ver, meta.i) then
        meta.bytes = #id + #cell
        metas[id] = meta
        total = total + meta.bytes
        byKey[meta.k] = byKey[meta.k] or {}
        byKey[meta.k][name .. "/" .. id] = { dev = name, id = id, meta = meta }
      else
        junk[#junk + 1] = id
        total = total + #id + #cell
      end
    end
    dir[name], used[name], devOk[name] = metas, total, true
    return junk
  end

  -- Read a device, change it, write it back. add: { id = cell }, remove: list of ids.
  -- With verify, the device is read again and the added cells compared.
  local function mutate(name, add, remove, verify)
    local D = devices[name]
    local cells = D.load()
    yield()
    if not cells then devOk[name] = false; return nil, "io" end
    for _, id in ipairs(remove or {}) do cells[id] = nil end
    for id, cell in pairs(add or {}) do cells[id] = cell end
    local ok = D.store(cells)
    yield()
    if not ok then return nil, "io" end
    if verify then
      local back = D.load()
      yield()
      if not back then devOk[name] = false; return nil, "io" end
      for id, cell in pairs(add) do
        if back[id] ~= cell then refresh(name, back); return nil, "io" end
      end
      cells = back
    end
    refresh(name, cells)
    return true
  end

  -- Work out the current state of one key from the cells that exist.
  -- Returns: entry (nil if deleted/absent), stale cell refs, tombstone cell refs, highest version seen.
  local function resolve(k)
    local set = byKey[k]
    if not set then return nil, {}, {}, 0 end
    local versions, maxVer = {}, 0
    for _, ref in pairs(set) do
      local m = ref.meta
      local v = versions[m.ver]
      if not v then
        v = { ver = m.ver, flag = m.flag, n = m.n, size = m.size, shards = {}, refs = {} }
        versions[m.ver] = v
      end
      v.refs[#v.refs + 1] = ref
      if m.flag == "d" and v.flag == "d" and m.n == v.n and m.i >= 1 and m.i <= m.n then
        local sh = v.shards[m.i]
        if not sh then sh = { hash = m.hash, devs = {} }; v.shards[m.i] = sh end
        if sh.hash == m.hash then sh.devs[#sh.devs + 1] = ref.dev end
      end
      if m.ver > maxVer then maxVer = m.ver end
    end
    local winner
    for ver, v in pairs(versions) do
      local complete = v.flag == "x"
      if not complete then
        complete = v.n >= 1
        for i = 1, v.n do
          if not v.shards[i] then complete = false; break end
        end
      end
      if complete and (not winner or ver > winner.ver) then winner = v end
    end
    local stale, tombs = {}, {}
    for _, v in pairs(versions) do
      for _, ref in ipairs(v.refs) do
        if v ~= winner then
          stale[#stale + 1] = ref
        elseif v.flag == "x" then
          tombs[#tombs + 1] = ref
        end
      end
    end
    if not winner or winner.flag == "x" then return nil, stale, tombs, maxVer end
    for _, sh in pairs(winner.shards) do table.sort(sh.devs) end
    return { ver = winner.ver, n = winner.n, size = winner.size, shards = winner.shards }, stale, tombs, maxVer
  end

  -- Remove a list of cell refs, one device write per device. Returns true if all were removed.
  local function removeRefs(refs)
    local per = {}
    for _, ref in ipairs(refs) do
      per[ref.dev] = per[ref.dev] or {}
      per[ref.dev][#per[ref.dev] + 1] = ref.id
    end
    local all = true
    for _, name in ipairs(order) do
      if per[name] and not mutate(name, nil, per[name]) then all = false end
    end
    return all
  end

  local function allDevicesReadable()
    for _, name in ipairs(order) do
      if not devOk[name] then return false end
    end
    return true
  end

  -- Bring one key to its clean state: drop stale cells, finish deletes.
  local function settle(k)
    local entry, stale, tombs = resolve(k)
    local clean = removeRefs(stale)
    if not entry and #tombs > 0 and clean and allDevicesReadable() then removeRefs(tombs) end
    index[k] = entry
    return entry
  end

  -- Choose devices for a set of cells. sizes[i] = bytes of cell i. Returns { [i] = { name... } } or nil.
  local function place(sizes, want)
    local free = {}
    for _, name in ipairs(order) do
      if devOk[name] then free[name] = deviceMax - used[name] end
    end
    local plan = {}
    for i, bytes in ipairs(sizes) do
      local picked = {}
      for _ = 1, want do
        local best
        for _, name in ipairs(order) do
          if free[name] and free[name] >= bytes and not picked[name]
              and (not best or free[name] > free[best]) then
            best = name
          end
        end
        if not best then return nil end
        picked[best] = true
        picked[#picked + 1] = best
        free[best] = free[best] - bytes
      end
      plan[i] = picked
    end
    return plan
  end

  local function readyCount()
    local n = 0
    for _, name in ipairs(order) do
      if devOk[name] then n = n + 1 end
    end
    return n
  end

  -- Write a set of new cells: cells[i] = { id, text }. Returns true or nil, err; on error nothing new remains.
  local function writeCells(cells)
    local want = math.min(replicas, readyCount())
    if want < 1 then return nil, "no_space" end
    local sizes = {}
    for i, c in ipairs(cells) do sizes[i] = #c.id + #c.text end
    local plan = place(sizes, want)
    if not plan then return nil, "no_space" end
    local per = {}
    for i, names in ipairs(plan) do
      for _, name in ipairs(names) do
        per[name] = per[name] or {}
        per[name][cells[i].id] = cells[i].text
      end
    end
    local done = {}
    for _, name in ipairs(order) do
      if per[name] then
        done[#done + 1] = name
        if not mutate(name, per[name], nil, true) then
          -- undo: remove whatever of the new version got written
          for _, written in ipairs(done) do
            local ids = {}
            for id in pairs(per[written]) do ids[#ids + 1] = id end
            mutate(written, nil, ids)
          end
          return nil, "io"
        end
      end
    end
    return true
  end

  local function guarded(fn)
    return function(...)
      if locked then return nil, "busy" end
      locked = true
      local res = { pcall(fn, ...) }
      locked = false
      if not res[1] then error(res[2], 0) end
      return table.unpack(res, 2)
    end
  end

  -- Scan every device and rebuild the index. Run at boot and after taking over as primary.
  E.rebuild = guarded(function()
    local report = { devices = #order, unreadable = 0, cells = 0, keys = 0, removed = 0 }
    byKey, index = {}, {}
    for _, name in ipairs(order) do dir[name] = {} end
    for _, name in ipairs(order) do
      local cells = devices[name].load()
      yield()
      if not cells then
        devOk[name] = false
        report.unreadable = report.unreadable + 1
      else
        local junk = refresh(name, cells)
        if #junk > 0 and mutate(name, nil, junk) then report.removed = report.removed + #junk end
      end
    end
    local keys = {}
    for k in pairs(byKey) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local _, stale = resolve(k)
      report.removed = report.removed + #stale
      if settle(k) then report.keys = report.keys + 1 end
    end
    for _, name in ipairs(order) do
      for _ in pairs(dir[name]) do report.cells = report.cells + 1 end
    end
    return report
  end)

  E.put = guarded(function(ns, key, value)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    if type(value) ~= "string" then return nil, "bad_value" end
    if #value > MAX_VALUE then return nil, "too_big" end
    local _, _, _, maxVer = resolve(k)
    local ver = maxVer + 1
    local n = math.max(1, math.ceil(#value / shardBytes))
    local cells = {}
    for i = 1, n do
      local part = value:sub((i - 1) * shardBytes + 1, i * shardBytes)
      cells[i] = { id = cellId(k, ver, i),
        text = makeCell(k, ver, i, n, #value, crypto.hashHex(part), "d", base64.encode(part)) }
      yield()
    end
    local ok, err = writeCells(cells)
    if not ok then return nil, err end
    settle(k) -- the new version is complete now; this removes the old one
    return true
  end)

  E.get = guarded(function(ns, key)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    local entry = index[k]
    if not entry then return nil, "not_found" end
    local parts, loaded = {}, {}
    for i = 1, entry.n do
      local sh, id = entry.shards[i], cellId(k, entry.ver, i)
      for _, name in ipairs(sh.devs) do
        if loaded[name] == nil then
          loaded[name] = devices[name] and devices[name].load() or false
          yield()
        end
        local cell = loaded[name] and loaded[name][id]
        if cell then
          local meta, nl = parseHeader(cell)
          local data = meta and base64.decode(cell:sub(nl + 1))
          if data and crypto.hashHex(data) == sh.hash then parts[i] = data; break end
        end
      end
      if not parts[i] then return nil, "corrupt" end
    end
    return table.concat(parts)
  end)

  E.delete = guarded(function(ns, key)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    if not index[k] then return nil, "not_found" end
    local _, _, _, maxVer = resolve(k)
    local ver = maxVer + 1
    local ok, err = writeCells({ { id = cellId(k, ver, 0), text = makeCell(k, ver, 0, 0, 0, "-", "x", "") } })
    if not ok then return nil, err end
    settle(k) -- the tombstone wins now; this removes the data, then the tombstone
    return true
  end)

  -- Keys in a namespace, sorted. Returns keys, more.
  function E.list(ns, prefix, after, limit)
    if type(ns) ~= "string" or not NAMESPACES[ns] then return {}, false end
    local want = ns .. "/" .. (prefix or "")
    local keys = {}
    for k in pairs(index) do
      if k:sub(1, #want) == want then
        local key = k:sub(#ns + 2)
        if not after or key > after then keys[#keys + 1] = key end
      end
    end
    table.sort(keys)
    limit = limit or 1000
    local more = #keys > limit
    for i = #keys, limit + 1, -1 do keys[i] = nil end
    return keys, more
  end

  function E.stat(ns, key)
    local k = checkName(ns, key)
    local entry = k and index[k]
    if not entry then return nil end
    return { size = entry.size, ver = entry.ver, shards = entry.n }
  end

  return E
end

return engine
