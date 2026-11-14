local t = require("test.t")
local sha = require("lib.sha256")

local T = {}

function T.known_vectors()
  t.eq(sha.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  t.eq(sha.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  t.eq(sha.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end

function T.million_a_streaming()
  local h = sha.new()
  local block = ("a"):rep(4096)
  local left = 1000000
  while left > 0 do
    local n = math.min(left, 4096)
    h:update(block:sub(1, n))
    left = left - n
  end
  t.eq(h:finish(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
end

function T.split_points_do_not_matter()
  local data = {}
  for i = 1, 300 do data[i] = string.char((i * 7) % 256) end
  data = table.concat(data)
  local want = sha.hex(data)
  for _, piece in ipairs({ 1, 55, 56, 64, 65, 127 }) do
    local h = sha.new()
    for i = 1, #data, piece do h:update(data:sub(i, i + piece - 1)) end
    t.eq(h:finish(), want, "piece size " .. piece)
  end
end

return T
