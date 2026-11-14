-- Loads and saves per-role config files. A config file is plain data: `return { ... }`.
-- It is run with an empty environment, so it cannot call any function or touch the computer.
local S = require("lib.schema")

local config = {}

local function fill(spec, value)
  if spec.kind ~= "map" then return value end
  for k, sub in pairs(spec.fields) do
    if type(value[k]) == "table" then fill(sub, value[k]) end
  end
  for k, sub in pairs(spec.optional) do
    if value[k] == nil then
      if sub.default ~= nil then
        value[k] = sub.default
      elseif sub.kind == "map" then
        value[k] = {}
      elseif sub.kind == "array" then
        value[k] = {}
      end
    end
    if type(value[k]) == "table" then fill(sub, value[k]) end
  end
  return value
end

-- Returns the config table, or nil plus a message that names the file and the bad key.
function config.load(fs, path, spec)
  local h = fs.open(path, "r")
  if not h then return nil, path .. ": cannot open" end
  local src = h.readAll()
  h.close()
  local fn, err = load(src, "=" .. path, "t", {})
  if not fn then return nil, path .. ": " .. tostring(err) end
  local ok, cfg = pcall(fn)
  if not ok then return nil, path .. ": " .. tostring(cfg) end
  if type(cfg) ~= "table" then return nil, path .. ": must return a table" end
  local good, why = S.check(spec, cfg)
  if not good then return nil, path .. ": " .. why end
  fill(spec, cfg)
  -- defaults themselves must be valid; this catches mistakes in a spec
  good, why = S.check(spec, cfg)
  if not good then return nil, path .. ": bad default: " .. why end
  return cfg
end

local function serialise(v, indent)
  local tv = type(v)
  if tv == "string" then return ("%q"):format(v) end
  if tv == "number" or tv == "boolean" then return tostring(v) end
  if tv ~= "table" then error("config: cannot save a " .. tv) end
  local pad = ("  "):rep(indent + 1)
  local out = {}
  if #v > 0 then
    for i = 1, #v do out[#out + 1] = pad .. serialise(v[i], indent + 1) .. "," end
  else
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      out[#out + 1] = pad .. "[" .. ("%q"):format(k) .. "] = " .. serialise(v[k], indent + 1) .. ","
    end
  end
  if #out == 0 then return "{}" end
  return "{\n" .. table.concat(out, "\n") .. "\n" .. ("  "):rep(indent) .. "}"
end

-- Writes to a temporary file first, so a crash or full disk never leaves a broken config.
-- Returns true, or nil plus an error.
function config.save(fs, path, cfg)
  local tmp = path .. ".tmp"
  local ok, err = pcall(function()
    local h = assert(fs.open(tmp, "w"))
    h.write("return " .. serialise(cfg, 0) .. "\n")
    h.close()
  end)
  if not ok then
    pcall(fs.delete, tmp)
    return nil, path .. ": " .. tostring(err)
  end
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

return config
