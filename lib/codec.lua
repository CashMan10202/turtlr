-- Strict binary encoder/decoder for protocol messages.
-- Supports only: booleans, integers (|n| <= 2^53), strings, arrays, and maps with string keys.
-- decode() never throws and never executes anything, so it is safe on untrusted bytes.
--
-- Wire format: one tag byte, then the payload.
--   0x00 false | 0x01 true
--   0x02 integer >= 0: varint | 0x06 integer < 0: varint of the magnitude
--   0x03 string:  varint length, bytes
--   0x04 array:   varint count, items
--   0x05 map:     varint count, (varint key length, key bytes, value) pairs, keys sorted
local codec = {}

local MAX_INT = 2 ^ 53
local floor, char, byte = math.floor, string.char, string.byte

local function putVarint(out, n)
  while n >= 128 do
    out[#out + 1] = char(n % 128 + 128)
    n = floor(n / 128)
  end
  out[#out + 1] = char(n)
end

local function putString(out, s)
  putVarint(out, #s)
  out[#out + 1] = s
end

local function enc(out, v, depth)
  local tv = type(v)
  if tv == "boolean" then
    out[#out + 1] = v and "\1" or "\0"
  elseif tv == "number" then
    if v ~= v or v ~= floor(v) or v > MAX_INT or v < -MAX_INT then
      error("codec: number is not a safe integer: " .. tostring(v), 0)
    end
    out[#out + 1] = v >= 0 and "\2" or "\6"
    putVarint(out, v >= 0 and v or -v)
  elseif tv == "string" then
    out[#out + 1] = "\3"
    putString(out, v)
  elseif tv == "table" then
    if depth > 64 then error("codec: table nested too deeply", 0) end
    local n, strKeys = 0, {}
    for k in pairs(v) do
      n = n + 1
      if type(k) == "string" then strKeys[#strKeys + 1] = k end
    end
    if #strKeys == 0 then
      -- array (an empty table is an empty array)
      if n ~= #v then error("codec: array has holes or non-string keys", 0) end
      out[#out + 1] = "\4"
      putVarint(out, n)
      for i = 1, n do enc(out, v[i], depth + 1) end
    else
      if #strKeys ~= n then error("codec: table mixes string and non-string keys", 0) end
      table.sort(strKeys)
      out[#out + 1] = "\5"
      putVarint(out, n)
      for i = 1, n do
        putString(out, strKeys[i])
        enc(out, v[strKeys[i]], depth + 1)
      end
    end
  else
    error("codec: cannot encode a " .. tv, 0)
  end
end

function codec.encode(value)
  local out = {}
  enc(out, value, 1)
  return table.concat(out)
end

-- Decoder state is passed explicitly: s (input), st.pos, st.items (budget left).
local function getVarint(s, st)
  local n, mul = 0, 1
  for i = 1, 8 do
    local b = byte(s, st.pos)
    if not b then return nil, "truncated varint" end
    st.pos = st.pos + 1
    if b < 128 then
      n = n + b * mul
      if n > MAX_INT then return nil, "varint too large" end
      return n
    end
    n = n + (b - 128) * mul
    mul = mul * 128
    if i == 8 then return nil, "varint too long" end
  end
end

local function getString(s, st)
  local len, err = getVarint(s, st)
  if not len then return nil, err end
  if len > #s - st.pos + 1 then return nil, "string length exceeds input" end
  local v = s:sub(st.pos, st.pos + len - 1)
  st.pos = st.pos + len
  return v
end

local function dec(s, st, depth)
  st.items = st.items - 1
  if st.items < 0 then return nil, "too many items" end
  local tag = byte(s, st.pos)
  if not tag then return nil, "truncated" end
  st.pos = st.pos + 1
  if tag == 0 then return false end
  if tag == 1 then return true end
  if tag == 2 or tag == 6 then
    local n, err = getVarint(s, st)
    if not n then return nil, err end
    if tag == 2 then return n end
    if n == 0 then return nil, "negative zero" end
    return -n
  end
  if tag == 3 then return getString(s, st) end
  if tag == 4 or tag == 5 then
    if depth > st.maxDepth then return nil, "nested too deeply" end
    local count, err = getVarint(s, st)
    if not count then return nil, err end
    -- every item needs at least one byte, so a count beyond the remaining input is a lie
    if count > #s - st.pos + 1 then return nil, "count exceeds input" end
    local t = {}
    if tag == 4 then
      for i = 1, count do
        local v, e = dec(s, st, depth + 1)
        if v == nil then return nil, e or "bad item" end
        t[i] = v
      end
    else
      for _ = 1, count do
        local k, e = getString(s, st)
        if not k then return nil, e end
        if t[k] ~= nil then return nil, "duplicate key" end
        local v, e2 = dec(s, st, depth + 1)
        if v == nil then return nil, e2 or "bad value" end
        t[k] = v
      end
    end
    return t
  end
  return nil, "unknown tag " .. tag
end

-- Returns value, or nil plus an error string. Note: a decoded `false` returns false with no error.
function codec.decode(s, opts)
  if type(s) ~= "string" then return nil, "input is not a string" end
  local st = { pos = 1, items = opts and opts.maxItems or 4096, maxDepth = opts and opts.maxDepth or 8 }
  local v, err = dec(s, st, 1)
  if v == nil then return nil, err or "decode failed" end
  if st.pos <= #s then return nil, "trailing bytes" end
  return v
end

return codec
