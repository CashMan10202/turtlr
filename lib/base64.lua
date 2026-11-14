-- Base64 (RFC 4648). Used to store arbitrary bytes as plain text inside NBT Storage blocks.
local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  local c = ALPHABET:sub(i, i)
  enc[i - 1] = c
  dec[c:byte()] = i - 1
end

local floor, char, byte = math.floor, string.char, string.byte

function base64.encode(s)
  local out, n = {}, 0
  for i = 1, #s - 2, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + b * 256 + c
    n = n + 1
    out[n] = enc[floor(v / 262144)] .. enc[floor(v / 4096) % 64] .. enc[floor(v / 64) % 64] .. enc[v % 64]
  end
  local rest = #s % 3
  if rest == 1 then
    local v = byte(s, #s) * 16
    out[n + 1] = enc[floor(v / 64)] .. enc[v % 64] .. "=="
  elseif rest == 2 then
    local a, b = byte(s, #s - 1, #s)
    local v = (a * 256 + b) * 4
    out[n + 1] = enc[floor(v / 4096)] .. enc[floor(v / 64) % 64] .. enc[v % 64] .. "="
  end
  return table.concat(out)
end

-- Returns the bytes, or nil if the text is not valid base64.
function base64.decode(s)
  if type(s) ~= "string" or #s % 4 ~= 0 then return nil end
  local out, n = {}, 0
  local last = #s - 3
  for i = 1, #s, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    local va, vb, vc, vd = dec[a], dec[b], dec[c], dec[d]
    if not va or not vb then return nil end
    n = n + 1
    if vc and vd then
      local v = va * 262144 + vb * 4096 + vc * 64 + vd
      out[n] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
    else
      -- padding is only allowed in the final group
      if i ~= last or d ~= 61 then return nil end
      if c == 61 then
        out[n] = char(va * 4 + floor(vb / 16))
      elseif vc then
        local v = va * 4096 + vb * 64 + vc
        out[n] = char(floor(v / 1024), floor(v / 4) % 256)
      else
        return nil
      end
    end
  end
  return table.concat(out)
end

return base64
