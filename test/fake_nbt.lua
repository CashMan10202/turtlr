-- Fake Advanced Peripherals NBT Storage for tests.
--   local periph, ctl = fake_nbt.new{ limit = 1048576, style = "writeTable", power = sharedPower }
-- style picks which write method the fake exposes (the real name is unverified until `verify` runs).
-- power (optional, shared between devices) simulates a power cut: once power.writesLeft hits 0,
-- every further write throws.
local fake_nbt = {}

local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = type(v) == "table" and copy(v) or v end
  return o
end

local function size(t)
  local n = 0
  for k, v in pairs(t) do
    n = n + #tostring(k) + (type(v) == "table" and size(v) or #tostring(v))
  end
  return n
end

-- minimal JSON object parser for flat { "key": "string" } objects (what the adapter writes)
local function parseFlatJson(s)
  local out = {}
  local pos = 1
  while true do
    local ks, ke = s:find('"', pos, true)
    if not ks then break end
    local kend = s:find('"', ke + 1, true)
    local key = s:sub(ke + 1, kend - 1)
    local vs = s:find('"', kend + 1, true)
    local i, buf = vs + 1, {}
    while true do
      local c = s:sub(i, i)
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        buf[#buf + 1] = n == "n" and "\n" or n
        i = i + 2
      elseif c == '"' then
        break
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
    out[key] = table.concat(buf)
    pos = i + 1
  end
  return out
end

function fake_nbt.new(opts)
  opts = opts or {}
  local limit, style, power = opts.limit or 1048576, opts.style or "writeTable", opts.power
  local stored = {}
  local ctl = { writes = 0, reads = 0, failNext = 0, readGarbage = false }

  local function write(tbl)
    if ctl.failNext > 0 then ctl.failNext = ctl.failNext - 1; error("peripheral detached") end
    if power then
      if power.writesLeft <= 0 then error("power lost") end
      power.writesLeft = power.writesLeft - 1
    end
    if type(tbl) ~= "table" then return nil, "not a table" end
    if size(tbl) > limit then return nil, "NBT data is too large" end
    stored = copy(tbl)
    ctl.writes = ctl.writes + 1
    return true
  end

  local periph = {}
  function periph.read()
    if ctl.failNext > 0 then ctl.failNext = ctl.failNext - 1; error("peripheral detached") end
    ctl.reads = ctl.reads + 1
    if ctl.readGarbage then return ctl.readGarbage end
    return copy(stored)
  end
  if style == "writeJson" then
    periph.writeJson = function(json)
      if type(json) ~= "string" then error("expected string") end
      return write(parseFlatJson(json))
    end
  else
    periph[style] = write
  end

  function ctl.fail(n) ctl.failNext = n end
  function ctl.wipe() stored = {} end
  function ctl.dump() return copy(stored) end
  function ctl.set(tbl) stored = copy(tbl) end
  -- damage one entry (or the first one found): flips a character in the middle of its value
  function ctl.corrupt(key)
    key = key or next(stored)
    local v = stored[key]
    local mid = math.floor(#v / 2) + 1
    local c = v:sub(mid, mid)
    stored[key] = v:sub(1, mid - 1) .. (c == "A" and "B" or "A") .. v:sub(mid + 1)
    return key
  end
  function ctl.keys()
    local out = {}
    for k in pairs(stored) do out[#out + 1] = k end
    table.sort(out)
    return out
  end

  return periph, ctl
end

return fake_nbt
