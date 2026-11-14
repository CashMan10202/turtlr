local t = require("test.t")
local ratelimit = require("lib.ratelimit")
local T = {}

function T.burst_then_steady_rate()
  local now = 0
  local rl = ratelimit.new({ burst = 5, perMinute = 60, clock = function() return now end })
  for _ = 1, 5 do t.ok(rl.allow("a")) end
  t.ok(not rl.allow("a"))
  now = 1000 -- one token per second at 60/min
  t.ok(rl.allow("a")); t.ok(not rl.allow("a"))
  now = 600000
  for _ = 1, 5 do t.ok(rl.allow("a")) end
  t.ok(not rl.allow("a"), "tokens never exceed the burst size")
end

function T.keys_are_independent()
  local rl = ratelimit.new({ burst = 1, perMinute = 1, clock = function() return 0 end })
  t.ok(rl.allow("a")); t.ok(not rl.allow("a")); t.ok(rl.allow("b"))
end

function T.memory_is_bounded()
  local now = 0
  local rl = ratelimit.new({ burst = 1, perMinute = 60, clock = function() return now end, maxKeys = 100 })
  for i = 1, 1000 do rl.allow("k" .. i); now = now + 1 end
  t.ok(rl.size() <= 100)
end

function T.clock_going_backwards_is_harmless()
  local now = 5000
  local rl = ratelimit.new({ burst = 2, perMinute = 60, clock = function() return now end })
  rl.allow("a"); rl.allow("a")
  now = 0
  t.ok(not rl.allow("a"))
end

return T
