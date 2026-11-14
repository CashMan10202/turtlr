local t = require("test.t")
local b64 = require("lib.base64")
local T = {}

function T.rfc4648_vectors()
  local v = { [""] = "", f = "Zg==", fo = "Zm8=", foo = "Zm9v", foob = "Zm9vYg==", fooba = "Zm9vYmE=", foobar = "Zm9vYmFy" }
  for plain, enc in pairs(v) do
    t.eq(b64.encode(plain), enc)
    t.eq(b64.decode(enc), plain)
  end
end

function T.all_bytes_round_trip()
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  all = table.concat(all)
  for cut = 0, 3 do
    local s = all:sub(1, #all - cut)
    local enc = b64.encode(s)
    t.ok(not enc:find("[^A-Za-z0-9+/=]"))
    t.eq(b64.decode(enc), s)
  end
end

function T.large_value()
  local s = ("\0\255abc"):rep(50000)
  t.eq(b64.decode(b64.encode(s)), s)
end

function T.invalid_text_is_rejected()
  for _, bad in ipairs({ "Zg=", "Z", "Zm9v!", "Zg==Zg==", "=Zg=", "Zm9vY", 5 }) do
    t.eq(b64.decode(bad), nil, "accepted " .. tostring(bad))
  end
end

return T
