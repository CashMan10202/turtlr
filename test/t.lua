-- Tiny assertion helpers for tests.
local t = {}

local function show(v, depth)
  depth = depth or 0
  if type(v) == "string" then return string.format("%q", #v > 80 and v:sub(1, 80) .. "..." or v) end
  if type(v) ~= "table" or depth > 3 then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. show(v[k], depth + 1) end
  return "{" .. table.concat(out, ", ") .. "}"
end

local function deep(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function t.eq(actual, expected, msg)
  if not deep(actual, expected) then
    error((msg and msg .. ": " or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function t.ok(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end

-- Asserts that fn raises an error. Returns the error message.
function t.err(fn, msg)
  local ok, e = pcall(fn)
  if ok then error(msg or "expected an error, got none", 2) end
  return e
end

t.show = show
return t
