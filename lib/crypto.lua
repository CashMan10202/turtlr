-- Thin wrapper around the vendored ccryptolib, so the rest of the code uses a few simple calls.
--   hash  = BLAKE3            (integrity checks)
--   seal  = ChaCha20-Poly1305 (encrypt + authenticate with a shared 32-byte key)
local random = require("ccryptolib.random")
local blake3 = require("ccryptolib.blake3")
local aead = require("ccryptolib.aead")

local crypto = {}

-- Seed the random generator. Call once at program start with at least 32 bytes of unpredictable data.
function crypto.init(seed)
  if type(seed) ~= "string" or #seed < 32 then error("crypto.init needs a seed of at least 32 bytes", 2) end
  random.init(seed)
end

-- Seed from tiny timing differences on this computer (works in-game without any network).
function crypto.initWithTiming() random.initWithTiming() end

function crypto.ready() return random.isInit() end

function crypto.random(n)
  if not random.isInit() then error("crypto.random used before crypto.init", 2) end
  return random.random(n)
end

function crypto.hash(data) return blake3.digest(data) end

function crypto.hex(bytes)
  return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

function crypto.hashHex(data) return crypto.hex(blake3.digest(data)) end

-- Derive a 32-byte key from key material; different context strings give unrelated keys.
function crypto.kdf(context, material) return blake3.deriveKey(context)(material) end

-- The 12-byte nonce is the counter, little-endian. A counter must never repeat for one key.
local function nonce(counter)
  local out = {}
  for i = 1, 12 do
    out[i] = string.char(counter % 256)
    counter = math.floor(counter / 256)
  end
  return table.concat(out)
end

-- Returns ciphertext followed by a 16-byte tag.
function crypto.seal(key, counter, plaintext, aad)
  local ct, tag = aead.encrypt(key, nonce(counter), plaintext, aad or "")
  return ct .. tag
end

-- Returns the plaintext, or nil if anything was changed or the key/counter/aad do not match.
function crypto.open(key, counter, sealed, aad)
  if type(sealed) ~= "string" or #sealed < 16 or type(key) ~= "string" or #key ~= 32 then return nil end
  if type(counter) ~= "number" or counter < 0 then return nil end
  local ok, plain = pcall(aead.decrypt, key, nonce(counter), sealed:sub(-16), sealed:sub(1, -17), aad or "")
  if ok then return plain end
  return nil
end

return crypto
