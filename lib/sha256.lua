-- SHA-256 in pure Lua (uses bit32, available in CC: Tweaked and Lua 5.2).
-- Used to prove installed files and uploaded chunks were not altered.
local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift = bit32.rrotate, bit32.rshift
local byte = string.byte

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function block(h, s, at)
  local w = {}
  for i = 0, 15 do
    local a, b, c, d = byte(s, at + i * 4, at + i * 4 + 3)
    w[i + 1] = a * 16777216 + b * 65536 + c * 256 + d
  end
  for i = 17, 64 do
    local x, y = w[i - 15], w[i - 2]
    local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
    local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
  end
  local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  for i = 1, 64 do
    local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = (hh + S1 + ch + K[i] + w[i]) % 4294967296
    local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    local t2 = (S0 + maj) % 4294967296
    hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
  end
  h[1] = (h[1] + a) % 4294967296; h[2] = (h[2] + b) % 4294967296
  h[3] = (h[3] + c) % 4294967296; h[4] = (h[4] + d) % 4294967296
  h[5] = (h[5] + e) % 4294967296; h[6] = (h[6] + f) % 4294967296
  h[7] = (h[7] + g) % 4294967296; h[8] = (h[8] + hh) % 4294967296
end

local sha256 = {}
local Hasher = {}
Hasher.__index = Hasher

-- Streaming use: local h = sha256.new(); h:update(part); ...; local hex = h:finish()
function sha256.new()
  return setmetatable({
    h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
    buf = "", len = 0,
  }, Hasher)
end

function Hasher:update(s)
  self.len = self.len + #s
  local data = self.buf .. s
  local full = #data - #data % 64
  for at = 1, full, 64 do block(self.h, data, at) end
  self.buf = data:sub(full + 1)
  return self
end

function Hasher:finish()
  local bits = self.len * 8
  local pad = "\128" .. ("\0"):rep((55 - self.len) % 64)
  local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
  local function be(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
      math.floor(n / 256) % 256, n % 256)
  end
  local data = self.buf .. pad .. be(hi) .. be(lo)
  for at = 1, #data, 64 do block(self.h, data, at) end
  local out = {}
  for i = 1, 8 do out[i] = ("%08x"):format(self.h[i]) end
  return table.concat(out)
end

function sha256.hex(s)
  return sha256.new():update(s):finish()
end

return sha256
