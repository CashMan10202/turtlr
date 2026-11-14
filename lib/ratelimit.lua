-- Token-bucket rate limiter: each key may burst `burst` requests, then `perMinute` per minute.
local ratelimit = {}

function ratelimit.new(opts)
  local burst, perMs, clock = opts.burst, opts.perMinute / 60000, opts.clock
  local maxKeys = opts.maxKeys or 1024
  local buckets, count = {}, 0
  local rl = {}

  function rl.allow(key)
    local now = clock()
    local b = buckets[key]
    if not b then
      if count >= maxKeys then
        -- forget everything rather than grow without limit; worst case a flooder gets one new burst
        buckets, count = {}, 0
      end
      b = { tokens = burst, at = now }
      buckets[key], count = b, count + 1
    end
    if now > b.at then
      b.tokens = math.min(burst, b.tokens + (now - b.at) * perMs)
      b.at = now
    end
    if b.tokens >= 1 then
      b.tokens = b.tokens - 1
      return true
    end
    return false
  end

  function rl.size() return count end

  return rl
end

return ratelimit
