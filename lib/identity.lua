-- A device's identity file (/bs/device.lua): its id, owner, own keys and the edge public keys.
local identity = {}

local BIN = { "signSk", "signPk", "kxSk", "kxPk", "inPk", "outPk" }

local function hex(b) return (b:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

function identity.save(fs, path, id)
  local lines = { "-- This device's identity. SECRET: do not copy.", "return {" }
  lines[#lines + 1] = ("  id = %d, kind = %q, player = %q,"):format(id.id, id.kind, id.player)
  for _, k in ipairs(BIN) do lines[#lines + 1] = ('  %s = "%s",'):format(k, hex(id[k])) end
  lines[#lines + 1] = "}"
  local h = fs.open(path .. ".tmp", "w")
  h.write(table.concat(lines, "\n") .. "\n")
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
end

-- Returns the identity, or nil if the file is missing or damaged.
function identity.load(fs, path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local src = h.readAll()
  h.close()
  local fn = load(src, "=identity", "t", {})
  local ok, t = pcall(fn or error)
  if not ok or type(t) ~= "table" or type(t.id) ~= "number" or type(t.player) ~= "string"
      or (t.kind ~= "pocket" and t.kind ~= "worker") then
    return nil
  end
  for _, k in ipairs(BIN) do
    if type(t[k]) ~= "string" or #t[k] ~= 64 or t[k]:find("[^0-9a-f]") then return nil end
    t[k] = unhex(t[k])
  end
  return t
end

return identity
