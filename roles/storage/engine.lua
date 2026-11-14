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
  local lost = {}      -- k -> true when every copy of some shard is gone
  local degraded = {}  -- k -> true when a key may have fewer copies than wanted
  local locked = false
  local fromSnapshot = false
  local scrubPos = 0
  local hot, cacheMax = opts.hot or {}, opts.cacheBytes or 262144
  local cache, cacheUse, cacheBytes, cacheTick = {}, {}, 0, 0

  local function cacheDrop(k)
    if cache[k] then cacheBytes = cacheBytes - #cache[k]; cache[k], cacheUse[k] = nil, nil end
  end

  local function cachePut(k, value)
    cacheDrop(k)
    if not hot[k:match("^[a-z]+")] or #value > cacheMax then return end
    cacheTick = cacheTick + 1
    cache[k], cacheUse[k], cacheBytes = value, cacheTick, cacheBytes + #value
    while cacheBytes > cacheMax do
      local oldest
      for key, tick in pairs(cacheUse) do
        if not oldest or tick < cacheUse[oldest] then oldest = key end
      end
      cacheDrop(oldest)
    end
  end

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
    cacheDrop(k)
    lost[k] = nil
    return entry
  end

  local function readyCount()
    local n = 0
    for _, name in ipairs(order) do
      if devOk[name] then n = n + 1 end
    end
    return n
  end

  local function underReplicated(entry)
    local want = math.min(replicas, readyCount())
    for i = 1, entry.n do
      if #entry.shards[i].devs < want then return true end
    end
    return false
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
  local function rebuildInner()
    fromSnapshot = false
    lost, degraded, cache, cacheUse, cacheBytes = {}, {}, {}, {}, 0
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
      local entry = settle(k)
      if entry then
        report.keys = report.keys + 1
        if underReplicated(entry) then degraded[k] = true end
      end
    end
    for _, name in ipairs(order) do
      for _ in pairs(dir[name]) do report.cells = report.cells + 1 end
    end
    return report
  end
  E.rebuild = guarded(rebuildInner)

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

  local function getInner(k)
    local entry = index[k]
    if not entry then return nil, "not_found" end
    if cache[k] then
      cacheTick = cacheTick + 1
      cacheUse[k] = cacheTick
      return cache[k]
    end
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
        degraded[k] = true -- this copy was missing or damaged; scrub will repair it
      end
      if not parts[i] then return nil, "corrupt" end
    end
    local value = table.concat(parts)
    cachePut(k, value)
    return value
  end

  E.get = guarded(function(ns, key)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    local value, err = getInner(k)
    if value == nil and fromSnapshot then
      -- the boot snapshot may be out of date: scan for real, then try once more
      rebuildInner()
      value, err = getInner(k)
    end
    return value, err
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

  ---------------------------------------------------------------------------
  -- Maintenance
  ---------------------------------------------------------------------------

  -- Read one cell from a device and return its text only if its data matches its hash.
  local function readGoodCell(name, id, hash)
    local cells = devices[name] and devices[name].load()
    yield()
    local cell = cells and cells[id]
    if not cell then return nil end
    local meta, nl = parseHeader(cell)
    local data = meta and base64.decode(cell:sub(nl + 1))
    if data and crypto.hashHex(data) == hash then return cell end
    mutate(name, nil, { id }) -- damaged copy: remove it so it is not counted any more
    return nil
  end

  -- Make sure every shard of k has enough copies. Returns copies created, and true if the key is lost.
  local function repair(k)
    local entry = resolve(k)
    if not entry then
      -- no complete version left: if we knew this key, its data is gone
      if index[k] and not lost[k] then lost[k] = true; cacheDrop(k); return 0, true end
      return 0, false
    end
    index[k] = entry
    local want = math.min(replicas, readyCount())
    local made, gone = 0, false
    for i = 1, entry.n do
      local sh, id = entry.shards[i], cellId(k, entry.ver, i)
      if #sh.devs < want then
        local cell
        for _, name in ipairs(sh.devs) do
          cell = readGoodCell(name, id, sh.hash)
          if cell then break end
        end
        if not cell then
          gone = true
        else
          local holders = {}
          for _, name in ipairs(sh.devs) do holders[name] = true end
          for _ = #sh.devs + 1, want do
            local best
            for _, name in ipairs(order) do
              if devOk[name] and not holders[name] and deviceMax - used[name] >= #id + #cell
                  and (not best or used[name] < used[best]) then
                best = name
              end
            end
            if not best or not mutate(best, { [id] = cell }, nil, true) then break end
            holders[best] = true
            made = made + 1
          end
        end
      end
    end
    local after = resolve(k)
    if gone or not after then
      local newly = not lost[k]
      lost[k] = true
      cacheDrop(k)
      return made, newly
    end
    index[k] = after
    if not underReplicated(after) then degraded[k] = nil end
    return made, false
  end

  -- Check one device (round-robin): verify every cell, drop damaged ones, then repair any key that
  -- is short of copies. Call regularly from the server's idle loop.
  E.scrubStep = guarded(function()
    local report = { checked = 0, bad = 0, repaired = 0, lost = 0 }
    if #order == 0 then return report end
    scrubPos = scrubPos % #order + 1
    local name = order[scrubPos]
    report.device = name
    local affected = {}
    for _, meta in pairs(dir[name]) do affected[meta.k] = true end
    local cells = devices[name].load()
    yield()
    if not cells then
      devOk[name] = false
      report.error = "io"
      return report
    end
    local bad = refresh(name, cells)
    for id, meta in pairs(dir[name]) do
      report.checked = report.checked + 1
      affected[meta.k] = true
      if meta.flag == "d" then
        local data = base64.decode(cells[id]:sub((cells[id]:find("\n", 1, true)) + 1))
        if not data or crypto.hashHex(data) ~= meta.hash then bad[#bad + 1] = id end
      end
      yield()
    end
    report.bad = #bad
    if #bad > 0 then mutate(name, nil, bad) end
    for k in pairs(degraded) do affected[k] = true end
    local keys = {}
    for k in pairs(affected) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      if index[k] then
        local made, newlyLost = repair(k)
        report.repaired = report.repaired + made
        if newlyLost then report.lost = report.lost + 1 end
      end
    end
    return report
  end)

  -- Move cells from the fullest device to the emptiest until fill differs by 30 % or less.
  E.rebalance = guarded(function(maxMoves)
    maxMoves = maxMoves or 200
    local moved = 0
    while moved < maxMoves do
      local hi, lo
      for _, name in ipairs(order) do
        if devOk[name] then
          if not hi or used[name] > used[hi] then hi = name end
          if not lo or used[name] < used[lo] then lo = name end
        end
      end
      if not hi or hi == lo or (used[hi] - used[lo]) / deviceMax <= 0.3 then break end
      -- pick cells to move: not already on the target, total at most half the difference
      local budget, ids = (used[hi] - used[lo]) / 2, {}
      for id, meta in pairs(dir[hi]) do
        if not dir[lo][id] and meta.bytes <= budget and moved + #ids < maxMoves then
          ids[#ids + 1] = id
          budget = budget - meta.bytes
        end
      end
      if #ids == 0 then break end
      local cells = devices[hi].load()
      yield()
      if not cells then devOk[hi] = false; break end
      local add, keys = {}, {}
      for _, id in ipairs(ids) do
        add[id] = cells[id]
        keys[dir[hi][id].k] = true
      end
      if not mutate(lo, add, nil, true) then break end
      local removed = mutate(hi, nil, ids)
      -- the copies moved: point the index at where they are now
      for k in pairs(keys) do
        local entry = resolve(k)
        if entry then index[k] = entry end
      end
      if not removed then break end
      moved = moved + #ids
    end
    return moved
  end)

  local function resettleDevice(name)
    local keys = {}
    for _, meta in pairs(dir[name]) do keys[meta.k] = true end
    for k in pairs(keys) do
      local entry = resolve(k)
      if entry then
        index[k] = entry
        if underReplicated(entry) then degraded[k] = true end
      end
    end
  end

  -- Start using another NBT Storage block.
  E.addDevice = guarded(function(D)
    if devices[D.name] then return nil, "exists" end
    addDevice(D)
    local cells = D.load()
    if not cells then devOk[D.name] = false; return true end
    refresh(D.name, cells)
    resettleDevice(D.name)
    return true
  end)

  -- Stop using a block: its cells are copied to other devices first.
  E.removeDevice = guarded(function(name)
    if not devices[name] then return nil, "not_found" end
    local cells = devices[name].load()
    yield()
    if not cells then return nil, "io" end
    refresh(name, cells)
    -- plan a new home for every cell that would otherwise lose a copy
    local free, per = {}, {}
    for _, other in ipairs(order) do
      if other ~= name and devOk[other] then free[other] = deviceMax - used[other] end
    end
    local ids = {}
    for id in pairs(dir[name]) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local bytes, best = dir[name][id].bytes
      for _, other in ipairs(order) do
        if free[other] and free[other] >= bytes and not dir[other][id]
            and (not best or free[other] > free[best]) then
          best = other
        end
      end
      if not best then return nil, "no_space" end
      free[best] = free[best] - bytes
      per[best] = per[best] or {}
      per[best][id] = cells[id]
    end
    for _, other in ipairs(order) do
      if per[other] and not mutate(other, per[other], nil, true) then return nil, "io" end
    end
    devices[name].store({})
    local keys = {}
    for _, meta in pairs(dir[name]) do keys[meta.k] = true end
    refresh(name, {})
    devices[name], dir[name], used[name], devOk[name] = nil, nil, nil, nil
    for i, n in ipairs(order) do
      if n == name then table.remove(order, i); break end
    end
    for k in pairs(keys) do
      local entry = resolve(k)
      if entry then index[k] = entry end
    end
    return true
  end)

  function E.health()
    local h = { devices = {}, keys = 0, bytes = 0, used = 0, capacity = #order * deviceMax,
      degraded = 0, lost = 0, cacheBytes = cacheBytes }
    for _, name in ipairs(order) do
      local cells = 0
      for _ in pairs(dir[name]) do cells = cells + 1 end
      h.devices[#h.devices + 1] = { name = name, used = used[name], cells = cells,
        errors = devices[name].errors, ok = devOk[name] }
      h.used = h.used + used[name]
    end
    for k, entry in pairs(index) do
      h.keys = h.keys + 1
      h.bytes = h.bytes + entry.size
      if lost[k] then
        h.lost = h.lost + 1
      elseif underReplicated(entry) then
        h.degraded = h.degraded + 1
      end
    end
    return h
  end

  -- The index as text, to save on local disk so the next boot can skip the full scan.
  function E.snapshot()
    local lines = { "BKSNAP 1" }
    for _, name in ipairs(order) do
      local ids = {}
      for id in pairs(dir[name]) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local m = dir[name][id]
        lines[#lines + 1] = table.concat({ name, id, m.k, m.ver, m.i, m.n, m.size, m.hash, m.flag, m.bytes }, "|")
      end
    end
    return table.concat(lines, "\n") .. "\n"
  end

  -- Load a snapshot instead of scanning. Returns true, or nil if the text is not a valid snapshot
  -- (then call rebuild). A snapshot that turns out to be out of date triggers a rebuild on first miss.
  E.loadSnapshot = guarded(function(text)
    if type(text) ~= "string" or text:sub(1, 9) ~= "BKSNAP 1\n" then return nil end
    local parsed = {}
    for line in text:sub(10):gmatch("[^\n]+") do
      local name, id, k, ver, i, n, size, hash, flag, bytes = line:match(
        "^([^|]+)|(c%x+)|([a-z]+/[A-Za-z0-9_.:-]+)|(%d+)|(%d+)|(%d+)|(%d+)|([0-9a-f-]+)|([dx])|(%d+)$")
      if not name then return nil end
      parsed[#parsed + 1] = { name = name, id = id, meta = { k = k, ver = tonumber(ver), i = tonumber(i),
        n = tonumber(n), size = tonumber(size), hash = hash, flag = flag, bytes = tonumber(bytes) } }
    end
    byKey, index, lost, degraded = {}, {}, {}, {}
    for _, name in ipairs(order) do dir[name], used[name] = {}, 0 end
    for _, p in ipairs(parsed) do
      if devices[p.name] then
        dir[p.name][p.id] = p.meta
        used[p.name] = used[p.name] + p.meta.bytes
        byKey[p.meta.k] = byKey[p.meta.k] or {}
        byKey[p.meta.k][p.name .. "/" .. p.id] = { dev = p.name, id = p.id, meta = p.meta }
      end
    end
    for k in pairs(byKey) do index[k] = resolve(k) end
    fromSnapshot = true
    return true
  end)

  return E
end

return engine
