-- Generates docs/protocol.md from lib/proto.lua so the document can never drift from the code.
--   lua5.2 tools/gen_protocol_doc.lua > docs/protocol.md
package.path = "./?.lua;" .. package.path
local proto = require("lib.proto")

local out = {}
local function w(s) out[#out + 1] = s or "" end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function describe(spec)
  local k = spec.kind
  if k == "int" then return ("integer %s..%s"):format(("%.0f"):format(spec.min), ("%.0f"):format(spec.max)) end
  if k == "bool" then return "true/false" end
  if k == "str" then return "text, max " .. spec.max .. (spec.pattern and (" , form `" .. spec.pattern .. "`") or "") end
  if k == "bytes" then return "bytes, max " .. spec.max end
  if k == "hex" then return spec.len .. " hex characters" end
  if k == "id" then return "block/item ID (`namespace:name`)" end
  if k == "enum" then return "one of: `" .. table.concat(spec.values, "`, `") .. "`" end
  if k == "array" then return "list (max " .. spec.max .. ") of: " .. describe(spec.item) end
  if k == "map" then
    local parts = {}
    for _, name in ipairs(sortedKeys(spec.fields)) do parts[#parts + 1] = name end
    for _, name in ipairs(sortedKeys(spec.optional)) do parts[#parts + 1] = name .. "?" end
    return "table { " .. table.concat(parts, ", ") .. " }"
  end
  return k
end

local function fieldTable(spec)
  if next(spec.fields) == nil and next(spec.optional) == nil then
    w("_(no fields)_")
    return
  end
  w("| Field | Required | Allowed |")
  w("|---|---|---|")
  for _, name in ipairs(sortedKeys(spec.fields)) do
    w(("| `%s` | yes | %s |"):format(name, describe(spec.fields[name])))
  end
  for _, name in ipairs(sortedKeys(spec.optional)) do
    w(("| `%s` | no | %s |"):format(name, describe(spec.optional[name])))
  end
end

w("# BuildKit protocol v" .. proto.VERSION)
w()
w("_Generated from `lib/proto.lua` by `tools/gen_protocol_doc.lua`. Do not edit by hand._")
w()
w("## Channels")
w()
w("| Channel | Use |")
w("|---|---|")
w("| " .. proto.CH.IN .. " | devices (pockets, turtles) -> INCOMING |")
w("| " .. proto.CH.OUT .. " | OUTGOING -> devices |")
w("| " .. proto.CH.BUS .. " | internal bus between base computers |")
w("| " .. proto.CH.TEL .. " | heartbeats and telemetry to MONITOR |")
w()
w("Raw modem channels are used, not rednet, so no rednet sender information is ever trusted.")
w()
w("## Frames")
w()
w("External frame (device <-> edge):")
w()
w("```")
w("ver (1 byte) | devId (varint) | counter (varint) | AEAD ciphertext + tag")
w("```")
w()
w("- Key: BLAKE3-derived from X25519(device key, edge key). Nonce: the counter. The header is authenticated.")
w("- Plaintext: the encoded message followed by an Ed25519 signature over header + message.")
w("- INCOMING drops a frame if: too large, unknown or revoked device, counter not higher than the last one seen,")
w("  timestamp too far from server time, decryption fails, or the message does not match the tables below.")
w("- COMPUTE checks the signature again, so the gateway alone cannot invent requests.")
w()
w("Messages are packed with `lib/codec.lua` (booleans, integers, strings, lists, tables only).")
w("Text is never executed and there are no free-text fields that reach a turtle.")
w()
w("## Envelope")
w()
w("Request: `{ v = 1, t = <type>, id = <request number>, ts = <ms since 1970>, b = <body> }`")
w()
w("Response: `{ v = 1, t = <type>, re = <request number>, ok = true, b = <body> }`")
w("or `{ v = 1, t = <type>, re = <request number>, ok = false, err = <code> }`")
w()
w("Error codes: `" .. table.concat(proto.ERRORS, "`, `") .. "`")
w()
w("## Limits")
w()
w("| Name | Value |")
w("|---|---|")
for _, name in ipairs(sortedKeys(proto.LIMITS)) do w(("| %s | %d |"):format(name, proto.LIMITS[name])) end
w()
w("## Turtle limits")
w()
w("Set by the player on the pocket; every value is capped by `turtleMax` in the COMPUTE config.")
w()
w("| Field | Allowed | Default |")
w("|---|---|---|")
for _, name in ipairs(sortedKeys(proto.TURTLE_LIMITS.optional)) do
  local f = proto.TURTLE_LIMITS.optional[name]
  w(("| `%s` | %s | %s |"):format(name, describe(f), f.default == nil and "none" or tostring(f.default)))
end
w()
w("## Messages")
for _, ty in ipairs(sortedKeys(proto.requests)) do
  w()
  w("### `" .. ty .. "`")
  w()
  w("Request body:")
  w()
  fieldTable(proto.requests[ty])
  w()
  w("Response body:")
  w()
  fieldTable(proto.responses[ty])
end

io.write(table.concat(out, "\n"), "\n")
