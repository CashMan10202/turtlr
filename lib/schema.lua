-- Schema validator: describes exactly what a message may contain, and rejects everything else.
-- Build specs with the constructors below, then call S.check(spec, value).
local S = {}

local floor = math.floor

local function isInt(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == floor(v)
end

-- Constructors -------------------------------------------------------------
function S.int(min, max, default) return { kind = "int", min = min, max = max, default = default } end
function S.bool(default) return { kind = "bool", default = default } end
-- Printable ASCII text, optional Lua pattern it must match.
function S.str(maxLen, pattern) return { kind = "str", max = maxLen, pattern = pattern } end
-- Raw bytes (any content).
function S.bytes(maxLen) return { kind = "bytes", max = maxLen } end
-- Hex string of exactly len characters.
function S.hex(len) return { kind = "hex", len = len } end
-- Short identifier token: letters and digits only.
function S.tok(maxLen) return { kind = "str", max = maxLen, min = 1, pattern = "^[A-Za-z0-9]+$" } end
-- Namespaced block/item ID such as "minecraft:stone".
function S.id() return { kind = "id" } end
-- For clamp(), list enum values from most restrictive to least restrictive.
function S.enum(values, default)
  local set = {}
  for i, v in ipairs(values) do set[v] = i end
  return { kind = "enum", values = values, set = set, default = default }
end
function S.array(item, maxN) return { kind = "array", item = item, max = maxN } end
function S.map(fields, optional) return { kind = "map", fields = fields or {}, optional = optional or {} } end

-- Checking -----------------------------------------------------------------
local check

local checkers = {}

function checkers.int(spec, v)
  if not isInt(v) then return "not an integer" end
  if v < spec.min or v > spec.max then return "out of range " .. spec.min .. ".." .. spec.max end
end

function checkers.bool(_, v)
  if type(v) ~= "boolean" then return "not a boolean" end
end

function checkers.str(spec, v)
  if type(v) ~= "string" then return "not a string" end
  if #v > spec.max then return "longer than " .. spec.max end
  if spec.min and #v < spec.min then return "shorter than " .. spec.min end
  if v:find("[^\32-\126]") then return "contains non-printable characters" end
  if spec.pattern and not v:find(spec.pattern) then return "does not match the required form" end
end

function checkers.bytes(spec, v)
  if type(v) ~= "string" then return "not a string" end
  if #v > spec.max then return "longer than " .. spec.max end
end

function checkers.hex(spec, v)
  if type(v) ~= "string" then return "not a string" end
  if #v ~= spec.len or v:find("[^0-9a-fA-F]") then return "not " .. spec.len .. " hex characters" end
end

function checkers.id(_, v)
  if type(v) ~= "string" then return "not a string" end
  if #v > 96 or not v:find("^[a-z0-9_.-]+:[a-z0-9_./-]+$") then return "not a valid block/item ID" end
end

function checkers.enum(spec, v)
  if type(v) ~= "string" or not spec.set[v] then return "not one of the allowed values" end
end

function checkers.array(spec, v, path)
  if type(v) ~= "table" then return "not a list" end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n ~= #v then return "not a plain list" end
  if n > spec.max then return "more than " .. spec.max .. " entries" end
  for i = 1, n do
    local err = check(spec.item, v[i], path .. "[" .. i .. "]")
    if err then return err, true end
  end
end

function checkers.map(spec, v, path)
  if type(v) ~= "table" then return "not a table" end
  for k in pairs(v) do
    if type(k) ~= "string" or not (spec.fields[k] or spec.optional[k]) then
      return "unknown field " .. tostring(k)
    end
  end
  local prefix = path == "" and "" or path .. "."
  for k, sub in pairs(spec.fields) do
    local err = check(sub, v[k], prefix .. k)
    if err then return err, true end
  end
  for k, sub in pairs(spec.optional) do
    if v[k] ~= nil then
      local err = check(sub, v[k], prefix .. k)
      if err then return err, true end
    end
  end
end

-- returns nil when fine, or a full "path: reason" string
check = function(spec, v, path)
  local err, full = checkers[spec.kind](spec, v, path)
  if not err then return nil end
  if full then return err end
  return (path == "" and "value" or path) .. ": " .. err
end

-- Returns true, or nil plus "path: reason".
function S.check(spec, value)
  local err = check(spec, value, "")
  if err then return nil, err end
  return true
end

-- Clamp a table of player-chosen limits to the owner's maximums.
-- Never fails: bad or missing values fall back to the spec default, numbers are pulled into range,
-- booleans can only be true if the owner allows it, enums can only be as permissive as the owner's.
function S.clamp(spec, value, ownerMax)
  if type(value) ~= "table" then value = {} end
  ownerMax = ownerMax or {}
  local out = {}
  local function each(k, f)
    local v, cap = value[k], ownerMax[k]
    if f.kind == "int" then
      if not isInt(v) then v = f.default or f.min end
      local hi = f.max
      if isInt(cap) and cap < hi then hi = cap end
      out[k] = math.max(f.min, math.min(hi, v))
    elseif f.kind == "bool" then
      if type(v) ~= "boolean" then v = f.default or false end
      out[k] = v and cap ~= false
    elseif f.kind == "enum" then
      if not f.set[v] then v = f.default or f.values[1] end
      if f.set[cap] and f.set[cap] < f.set[v] then v = cap end
      out[k] = v
    elseif f.kind == "array" then
      out[k] = S.check(f, v) and v or {}
    elseif S.check(f, v) then
      out[k] = v
    end
  end
  for k, f in pairs(spec.fields) do each(k, f) end
  for k, f in pairs(spec.optional) do each(k, f) end
  return out
end

return S
