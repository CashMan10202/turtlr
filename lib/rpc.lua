-- Request/reply on top of the bus.
--
-- One coroutine must run R.pumpLoop(): it is the only place modem messages are decrypted, and it
-- turns them into local events. Any other coroutine can then use R.call(), and a server coroutine
-- runs R.serveLoop(handlers). In CC, start them with parallel.waitForAny.
--
--   local R = rpc.new{ bus = B, pull = os.pullEvent, startTimer = os.startTimer,
--                      queueEvent = os.queueEvent, clock = function() return os.epoch("utc") end }
local rpc = {}

local INBOX_MAX = 64

function rpc.new(opts)
  local B, pull, startTimer, queueEvent = opts.bus, opts.pull, opts.startTimer, opts.queueEvent
  local nextId = opts.clock() % 1000000 * 1000
  local inbox = {}
  local R = { bus = B }

  -- Feed one modem_message event in. Safe to call with any event.
  function R.pump(event, _, channel, _, payload)
    if event ~= "modem_message" then return end
    local got = B.receive(channel, payload)
    if not got then return end
    local msg = got.msg
    if msg.k == "r" and type(msg.id) == "number" then
      queueEvent("bus_reply", msg.id, got.src, msg)
    elseif (msg.k == "q" or msg.k == "n") and type(msg.m) == "string"
        and (msg.k == "n" or type(msg.id) == "number") then
      if #inbox < INBOX_MAX then
        inbox[#inbox + 1] = got
        queueEvent("bus_req")
      end
    end
  end

  function R.pumpLoop()
    while true do R.pump(pull("modem_message")) end
  end

  -- Returns the reply body, or nil plus an error code ("timeout", "no_key", or the server's code).
  function R.call(dst, method, body, timeoutSecs)
    nextId = nextId + 1
    local id = nextId
    local ok, err = B.send(dst, { k = "q", id = id, m = method, b = body or {} })
    if not ok then return nil, err end
    local timer = startTimer(timeoutSecs or 5)
    while true do
      local ev, a, b, c = pull()
      if ev == "bus_reply" and a == id and b == dst then
        if c.ok == 1 then return type(c.b) == "table" and c.b or {} end
        return nil, type(c.e) == "string" and c.e or "internal"
      elseif ev == "timer" and a == timer then
        return nil, "timeout"
      end
    end
  end

  -- Send without expecting a reply.
  function R.notify(dst, method, body)
    return B.send(dst, { k = "n", m = method, b = body or {} })
  end

  local function handle(handlers, got)
    local msg = got.msg
    local fn = handlers[msg.m]
    local ok, res, code
    if not fn then
      ok, res, code = true, nil, "no_method"
    else
      ok, res, code = pcall(fn, type(msg.b) == "table" and msg.b or {}, got.src, got.instance)
      if not ok then
        if opts.onError then pcall(opts.onError, msg.m, res) end
        res, code = nil, "internal"
      end
    end
    if msg.k ~= "q" then return end
    if res ~= nil then
      local sent = B.send(got.src, { k = "r", id = msg.id, ok = 1, b = res })
      if not sent then B.send(got.src, { k = "r", id = msg.id, ok = 0, e = "too_big" }) end
    else
      B.send(got.src, { k = "r", id = msg.id, ok = 0, e = tostring(code or "internal") })
    end
  end

  -- Handle everything waiting in the inbox. handlers[method] = function(body, srcRole, srcInstance)
  -- returning a reply table, or nil plus an error code.
  function R.serveOnce(handlers)
    local n = 0
    while #inbox > 0 do
      handle(handlers, table.remove(inbox, 1))
      n = n + 1
    end
    return n
  end

  function R.serveLoop(handlers)
    while true do
      R.serveOnce(handlers)
      if #inbox == 0 then pull("bus_req") end
    end
  end

  return R
end

return rpc
