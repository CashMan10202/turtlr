-- Link keys for the internal bus: one secret 32-byte key per pair of roles.
-- Each computer gets a file holding only the keys for its own role.
local keys_core = {}

-- The base computers that talk on the internal bus (not turtles, pockets or GPS hosts).
keys_core.ROLES = { "compute", "incoming", "ingest", "monitor", "outgoing", "register", "storage" }

-- random(n) must return n unpredictable bytes. Returns { [role] = { [peer] = key } }.
function keys_core.generate(random, roles)
  local all = {}
  for _, a in ipairs(roles) do all[a] = {} end
  for i, a in ipairs(roles) do
    for j = i, #roles do
      local key = random(32)
      all[a][roles[j]] = key
      all[roles[j]][a] = key
    end
  end
  return all
end

local function hex(bytes)
  return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

-- Lua source for one role's key file.
function keys_core.serialise(roleKeys)
  local peers = {}
  for peer in pairs(roleKeys) do peers[#peers + 1] = peer end
  table.sort(peers)
  local lines = { "-- BuildKit link keys. SECRET: never copy this file anywhere else.", "return {" }
  for _, peer in ipairs(peers) do
    lines[#lines + 1] = ('  %s = "%s",'):format(peer, hex(roleKeys[peer]))
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- Returns { [peer] = 32-byte key }, or nil plus an error.
function keys_core.load(fs, path)
  local h = fs.open(path, "r")
  if not h then return nil, path .. ": missing (run mkkeys load <role>)" end
  local src = h.readAll()
  h.close()
  local fn = load(src, "=keys", "t", {})
  local ok, tbl = pcall(fn or error)
  if not ok or type(tbl) ~= "table" then return nil, path .. ": not a valid key file" end
  local keys, n = {}, 0
  for peer, value in pairs(tbl) do
    if type(peer) ~= "string" or not peer:find("^[a-z]+$") or type(value) ~= "string"
        or #value ~= 64 or value:find("[^0-9a-f]") then
      return nil, path .. ": bad key entry"
    end
    keys[peer] = value:gsub("..", function(b) return string.char(tonumber(b, 16)) end)
    n = n + 1
  end
  if n == 0 then return nil, path .. ": no keys in file" end
  return keys
end

return keys_core
