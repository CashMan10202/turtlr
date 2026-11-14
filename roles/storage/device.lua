-- Adapter for one Advanced Peripherals NBT Storage block.
-- Presents it as a flat table of string -> string ("cells"). Never throws: every failure is
-- returned as nil plus a message and counted in D.errors.
local device = {}

local TYPES = { nbtStorage = true, nbt_storage = true }
-- Method names differ between Advanced Peripherals versions. Seen in-game on 1.21.1: load / save.
local READERS = { "load", "read" }
local WRITERS = { "save", "writeTable", "writeJson" }

-- Minecraft cannot store one NBT string longer than 65535 bytes, and Advanced Peripherals crashes
-- the whole server when asked to (instead of returning an error). Never send anything close to it.
device.MAX_STRING = 65000

local function toJson(cells)
  local parts = {}
  for k, v in pairs(cells) do
    parts[#parts + 1] = ('"%s":"%s"'):format(k, (v:gsub('[\\"]', "\\%0"):gsub("\n", "\\n")))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- methodNames: list from peripheral.getMethods. Returns D, or nil plus why it cannot be used.
function device.wrap(name, periph, methodNames)
  local has = {}
  for _, m in ipairs(methodNames or {}) do has[m] = true end
  local writer
  for _, m in ipairs(WRITERS) do
    if has[m] then writer = m; break end
  end
  local reader
  for _, m in ipairs(READERS) do
    if has[m] then reader = m; break end
  end
  if not reader or not writer then return nil, name .. ": no usable read/write methods" end

  local D = { name = name, errors = 0, junk = 0, writer = writer, reader = reader }

  -- Returns the cells table, or nil plus an error.
  function D.load()
    local ok, data = pcall(periph[reader])
    if not ok then
      D.errors = D.errors + 1
      return nil, tostring(data)
    end
    local cells = {}
    if type(data) ~= "table" then
      if data ~= nil then D.junk = D.junk + 1 end
      return cells
    end
    for k, v in pairs(data) do
      if type(k) == "string" and type(v) == "string" then cells[k] = v else D.junk = D.junk + 1 end
    end
    return cells
  end

  -- Replaces the whole content of the block. Returns true, or nil plus an error.
  function D.store(cells)
    for k, v in pairs(cells) do
      if #k > device.MAX_STRING or #v > device.MAX_STRING then
        D.errors = D.errors + 1
        return nil, "entry too long for NBT (" .. math.max(#k, #v) .. " bytes)"
      end
    end
    local arg = writer == "writeJson" and toJson(cells) or cells
    local ok, res, err = pcall(periph[writer], arg)
    -- success is "did not throw, did not return false, did not return nil plus a message"
    -- (some versions return nothing at all on success; the engine reads back to be sure)
    if ok and res ~= false and not (res == nil and err ~= nil) then return true end
    D.errors = D.errors + 1
    return nil, tostring(ok and (err or "write refused") or res)
  end

  return D
end

-- All usable NBT Storage blocks on the network, sorted by name.
function device.discover(peripheral)
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if TYPES[peripheral.getType(name)] then
      local D = device.wrap(name, peripheral.wrap(name), peripheral.getMethods(name))
      if D then found[#found + 1] = D end
    end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  return found
end

return device
