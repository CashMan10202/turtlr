-- Simulator: runs several fake computers ("nodes") with their own coroutines, event queues,
-- timers and modems on one fake network, with a virtual clock. Lets multi-computer protocols be
-- tested outside Minecraft.
--
--   local sim = require("test.sim").new()
--   local a = sim.node("a")
--   a.spawn(function() ... a.pull("timer") ... end)
--   sim.run(function() return done end)
local fake_net = require("test.fake_net")

local M = {}

function M.new(startMs)
  local sim = { net = fake_net.new() }
  local now = startMs or 1700000000000
  local nodes, timers, nextTimer = {}, {}, 0

  function sim.clock() return now end
  function sim.advance(ms) now = now + ms end

  function sim.node(name)
    local node = { name = name, modem = sim.net.modem(name), queue = {}, threads = {}, alive = true }

    function node.clock() return now end
    function node.pull(filter)
      local ev = { coroutine.yield(filter) }
      return table.unpack(ev)
    end
    function node.queueEvent(...) node.queue[#node.queue + 1] = { ... } end
    function node.startTimer(secs)
      nextTimer = nextTimer + 1
      timers[#timers + 1] = { at = now + secs * 1000, node = node, id = nextTimer }
      return nextTimer
    end
    function node.sleep(secs)
      local id = node.startTimer(secs)
      repeat local _, got = node.pull("timer") until got == id
    end
    -- cooperative yield, like os.queueEvent + os.pullEvent in CC
    function node.yield()
      node.queueEvent("__yield")
      node.pull("__yield")
    end

    function node.spawn(fn)
      local th = { co = coroutine.create(fn), filter = nil, started = false }
      node.threads[#node.threads + 1] = th
      return th
    end

    function node.kill()
      node.alive = false
      node.threads, node.queue = {}, {}
      sim.net.kill(name)
    end
    function node.revive()
      node.alive = true
      sim.net.revive(name)
    end

    nodes[#nodes + 1] = node
    return node
  end

  local function resume(node, th, ev)
    local ok, filter = coroutine.resume(th.co, table.unpack(ev or {}))
    if not ok then error("node " .. node.name .. " crashed: " .. tostring(filter), 0) end
    th.filter = filter
    th.started = true
  end

  local function deliver(node, ev)
    for _, th in ipairs({ table.unpack(node.threads) }) do
      if coroutine.status(th.co) == "suspended" and (th.filter == nil or th.filter == ev[1]) then
        resume(node, th, ev)
      end
    end
  end

  -- One scheduling step. Returns false when nothing at all can happen any more.
  local function step()
    local busy = false
    for _, node in ipairs(nodes) do
      if node.alive then
        for _, th in ipairs({ table.unpack(node.threads) }) do
          if not th.started then resume(node, th); busy = true end
        end
        local ev = table.remove(node.queue, 1) or sim.net.next(node.name)
        if ev then deliver(node, ev); busy = true end
      end
    end
    if busy then return true end
    -- nothing pending: jump the clock to the next timer
    table.sort(timers, function(a, b) return a.at < b.at end)
    local tm = table.remove(timers, 1)
    if not tm then return false end
    if tm.at > now then now = tm.at end
    if tm.node.alive then deliver(tm.node, { "timer", tm.id }) end
    return true
  end

  -- Runs until cond() is true. Returns true if it became true, false if the simulation went idle
  -- or maxSteps passed first.
  function sim.run(cond, maxSteps)
    for _ = 1, maxSteps or 200000 do
      if cond and cond() then return true end
      if not step() then return cond == nil or cond() or false end
    end
    return false
  end

  -- Runs for a span of virtual time.
  function sim.runFor(ms)
    local stop = now + ms
    local marker = sim.node("__clock" .. #nodes)
    local done = false
    marker.spawn(function() marker.sleep(ms / 1000); done = true end)
    sim.run(function() return done end)
    if now < stop then now = stop end
  end

  return sim
end

return M
