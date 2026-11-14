-- Client for the storage service. Used by every base computer that needs to keep data.
--
--   local store = storeclient.new{ rpc = R, sleep = sleep }
--   store.put("jobs", "J1", "bytes")        store.get("jobs", "J1")
--   store.putTable("jobs", "J1", { ... })   store.getTable("jobs", "J1")
--   store.delete / store.list / store.stat / store.health
-- Every call returns its result, or nil plus an error code.
local codec = require("lib.codec")

local storeclient = {}

local PART = 32768
local RETRY = { timeout = true, busy = true }

function storeclient.new(opts)
  local R, sleep = opts.rpc, opts.sleep
  -- short waits and several tries: a storage manager that just started (or just took over)
  -- stays silent for a few seconds, and a quick retry beats one long wait
  local retries = opts.retries or 4
  local timeout = opts.timeoutSecs or 6
  local nextUp = 0
  local C = {}

  -- one call with retries; a storage failover shows up as a few timeouts
  local function call(method, body)
    local res, err
    for attempt = 1, retries + 1 do
      res, err = R.call("storage", method, body, timeout)
      if res or not RETRY[err] then return res, err end
      if attempt <= retries and sleep then sleep(1) end
    end
    return nil, err
  end

  function C.put(ns, key, value)
    if type(value) ~= "string" then return nil, "bad_value" end
    if #value <= PART then
      local res, err = call("put", { ns = ns, key = key, d = value })
      if not res then return nil, err end
      return true
    end
    local n = math.ceil(#value / PART)
    for attempt = 1, retries + 1 do
      nextUp = nextUp + 1
      local up = "U" .. nextUp .. "x" .. (#value % 100000)
      local res, err
      for i = 1, n do
        res, err = call("put_part", { ns = ns, key = key, up = up, i = i, n = n,
          d = value:sub((i - 1) * PART + 1, i * PART) })
        if not res then break end
      end
      if res and res.done == 1 then return true end
      -- parts landed on a server that lost its memory (failover): start the upload again
      if res == nil and not RETRY[err] then return nil, err end
      if attempt > retries then return nil, err or "timeout" end
    end
  end

  function C.get(ns, key)
    for _ = 1, retries + 1 do
      local first, err = call("get_part", { ns = ns, key = key, i = 1 })
      if not first then return nil, err end
      local parts, changed = { first.d }, false
      for i = 2, first.n do
        local p, e = call("get_part", { ns = ns, key = key, i = i })
        if not p then
          if e ~= "bad_request" and e ~= "not_found" then return nil, e end
          changed = true
          break
        end
        if p.ver ~= first.ver then changed = true; break end
        parts[i] = p.d
      end
      if not changed then return table.concat(parts) end
      -- the value was replaced while we were reading it: read again
    end
    return nil, "busy"
  end

  function C.delete(ns, key)
    local res, err = call("delete", { ns = ns, key = key })
    if not res then return nil, err end
    return true
  end

  -- Returns keys, more (or nil, err).
  function C.list(ns, prefix, after, limit)
    local res, err = call("list", { ns = ns, prefix = prefix, after = after, limit = limit })
    if not res then return nil, err end
    return res.keys, res.more == 1
  end

  function C.stat(ns, key) return call("stat", { ns = ns, key = key }) end
  function C.health() return call("health", {}) end

  function C.putTable(ns, key, tbl)
    local ok, data = pcall(codec.encode, tbl)
    if not ok then return nil, "bad_value" end
    return C.put(ns, key, data)
  end

  function C.getTable(ns, key)
    local data, err = C.get(ns, key)
    if not data then return nil, err end
    local tbl = codec.decode(data, { maxItems = 200000, maxDepth = 16 })
    if type(tbl) ~= "table" then return nil, "corrupt" end
    return tbl
  end

  return C
end

return storeclient
