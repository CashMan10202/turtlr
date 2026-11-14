-- Storage server: exposes the engine over rpc, decides which manager is primary, and runs
-- background maintenance. Everything runs in ONE coroutine (S.loop) because the engine is not
-- re-entrant.
--
-- Primary election: every manager announces itself every 2 s. A manager is primary only while it
-- has heard no manager with a lower id for 6 s. Standbys stay silent to clients.
local rpc = require("lib.rpc")

local server = {}

local PART = 32768           -- bytes per transport part
local MAX_VALUE = 4194304
local MAX_UPLOADS = 4
local UPLOAD_IDLE_MS = 60000
local BEAT_MS = 2000
local TAKEOVER_MS = 6000

function server.new(opts)
  local E, R, id, clock, log = opts.engine, opts.rpc, opts.id, opts.clock, opts.log
  local scrubEveryMs = (opts.scrubEverySecs or 5) * 1000
  local started = clock()
  local lastLower = started   -- pretend a lower id was just heard: wait before claiming primary
  local lastBeat, lastScrub = 0, started
  local primary = false
  local uploads, uploadCount = {}, 0
  local served = nil          -- last value fetched for get_part: { k, ver, value }
  local S = { dirty = false }

  local function info(msg, fields) if log then log.info("storage", msg, fields) end end

  -- Announce ourselves. Called from the loop and from inside long engine operations.
  function S.beat()
    local now = clock()
    if now - lastBeat >= BEAT_MS then
      lastBeat = now
      R.notify("storage", "hb", { id = id, primary = primary and 1 or 0 })
    end
  end

  function S.isPrimary() return primary end
  function S.uploads() return uploadCount end

  local function becomePrimary()
    primary = true
    info("became primary", { id = id })
    local snap = opts.loadSnapshot and opts.loadSnapshot()
    if not (snap and E.loadSnapshot(snap)) then E.rebuild() end
    lastScrub = clock()
  end

  local function stepDown(lower)
    primary = false
    uploads, uploadCount, served = {}, 0, nil
    info("stepped down", { id = id, lower = lower })
  end

  -- wrap a data handler so that standbys do not answer at all
  local function data(fn)
    return function(body, src, instance)
      if not primary then return rpc.NOREPLY end
      return fn(body, src, instance)
    end
  end

  local function str(v, max) return type(v) == "string" and #v <= max end

  S.handlers = {}

  function S.handlers.hb(body, src)
    if src ~= "storage" or type(body.id) ~= "number" then return end
    if body.id < id then
      lastLower = clock()
      if primary then stepDown(body.id) end
    end
  end

  S.handlers.put = data(function(body)
    if not str(body.d, PART) then return nil, "bad_request" end
    local ok, err = E.put(body.ns, body.key, body.d)
    if not ok then return nil, err end
    S.dirty = true
    return {}
  end)

  S.handlers.put_part = data(function(body, src, instance)
    local i, n = body.i, body.n
    if not str(body.d, PART) or not str(body.up, 24) or type(i) ~= "number" or type(n) ~= "number"
        or n < 1 or n > MAX_VALUE / PART or i < 1 or i > n or i % 1 ~= 0 or n % 1 ~= 0 then
      return nil, "bad_request"
    end
    local uid = src .. ":" .. instance .. ":" .. body.up
    local up = uploads[uid]
    if not up then
      if uploadCount >= MAX_UPLOADS then return nil, "busy" end
      up = { ns = body.ns, key = body.key, n = n, parts = {}, have = 0, bytes = 0 }
      uploads[uid], uploadCount = up, uploadCount + 1
    end
    if up.n ~= n or up.ns ~= body.ns or up.key ~= body.key then return nil, "bad_request" end
    up.last = clock()
    if not up.parts[i] then
      up.parts[i], up.have, up.bytes = body.d, up.have + 1, up.bytes + #body.d
    end
    if up.have < up.n then return { done = 0 } end
    uploads[uid], uploadCount = nil, uploadCount - 1
    local ok, err = E.put(up.ns, up.key, table.concat(up.parts))
    if not ok then return nil, err end
    S.dirty = true
    return { done = 1 }
  end)

  S.handlers.get_part = data(function(body)
    local i = body.i
    if type(i) ~= "number" or i < 1 or i % 1 ~= 0 then return nil, "bad_request" end
    local st = E.stat(body.ns, body.key)
    if not st then
      -- let the engine produce the right error (bad_key / not_found)
      local _, err = E.get(body.ns, body.key)
      return nil, err or "not_found"
    end
    local k = body.ns .. "/" .. body.key
    if not (served and served.k == k and served.ver == st.ver) then
      local value, err = E.get(body.ns, body.key)
      if not value then return nil, err end
      served = { k = k, ver = st.ver, value = value }
    end
    local n = math.max(1, math.ceil(#served.value / PART))
    if i > n then return nil, "bad_request" end
    return { n = n, ver = st.ver, d = served.value:sub((i - 1) * PART + 1, i * PART) }
  end)

  S.handlers.delete = data(function(body)
    local ok, err = E.delete(body.ns, body.key)
    if not ok then return nil, err end
    S.dirty = true
    served = nil
    return {}
  end)

  S.handlers.list = data(function(body)
    local limit = type(body.limit) == "number" and math.min(body.limit, 200) or 200
    local keys, more = E.list(body.ns, type(body.prefix) == "string" and body.prefix or nil,
      type(body.after) == "string" and body.after or nil, limit)
    return { keys = keys, more = more and 1 or 0 }
  end)

  S.handlers.stat = data(function(body)
    local st = E.stat(body.ns, body.key)
    if not st then return nil, "not_found" end
    return st
  end)

  S.handlers.health = data(function()
    local h = E.health()
    local bad, errors = 0, 0
    for _, d in ipairs(h.devices) do
      if not d.ok then bad = bad + 1 end
      errors = errors + d.errors
    end
    return { id = id, devices = #h.devices, devicesBad = bad, deviceErrors = errors, keys = h.keys,
      bytes = h.bytes, used = h.used, capacity = h.capacity, degraded = h.degraded, lost = h.lost }
  end)

  -- Per-device detail for the monitor room, 20 devices per page.
  S.handlers.health_devices = data(function(body)
    local from = type(body.from) == "number" and math.max(1, math.floor(body.from)) or 1
    local h, out = E.health(), {}
    for i = from, math.min(#h.devices, from + 19) do
      local d = h.devices[i]
      out[#out + 1] = { name = d.name, used = d.used, cells = d.cells, errors = d.errors, ok = d.ok and 1 or 0 }
    end
    return { devices = out, total = #h.devices }
  end)

  -- Periodic work. Call at least once a second.
  function S.tick()
    local now = clock()
    S.beat()
    if not primary and now - lastLower > TAKEOVER_MS then becomePrimary() end
    for uid, up in pairs(uploads) do
      if now - up.last > UPLOAD_IDLE_MS then uploads[uid], uploadCount = nil, uploadCount - 1 end
    end
    if primary and now - lastScrub >= scrubEveryMs then
      lastScrub = now
      local r = E.scrubStep()
      if r.bad > 0 or r.repaired > 0 or r.lost > 0 or r.error then
        S.dirty = true
        if log then log.warn("storage", "scrub", r) end
      end
    end
    if primary and S.dirty and opts.saveSnapshot and now - (S.lastSave or 0) > 300000 then
      S.lastSave, S.dirty = now, false
      pcall(opts.saveSnapshot, E.snapshot())
    end
  end

  -- The server's single coroutine: handle requests, then periodic work, then wait.
  function S.loop(pull, startTimer)
    while true do
      R.serveOnce(S.handlers)
      S.tick()
      local timer = startTimer(1)
      while true do
        local ev, a = pull()
        if ev == "bus_req" or (ev == "timer" and a == timer) then break end
      end
    end
  end

  return S
end

return server
