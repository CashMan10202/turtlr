-- Minimal fake of the CC: Tweaked globals our libraries use (fs, os.epoch, peripheral),
-- so the code can be tested under plain Lua outside Minecraft.
local shim = {}

local function norm(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
  end
  return table.concat(parts, "/")
end

function shim.new()
  local env = { capacity = 1000000 }
  local files = {} -- normalised path -> content
  local dirs = { [""] = true }
  local now = 0

  local function used()
    local n = 0
    for _, c in pairs(files) do n = n + #c end
    return n
  end

  local function mkdirs(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
      acc = acc == "" and part or acc .. "/" .. part
      dirs[acc] = true
    end
  end

  local function parent(path) return path:match("^(.*)/[^/]*$") or "" end

  local fs = {}
  function fs.exists(p) p = norm(p); return files[p] ~= nil or dirs[p] == true end
  function fs.isDir(p) return dirs[norm(p)] == true end
  function fs.makeDir(p) mkdirs(norm(p)) end
  function fs.getSize(p)
    local c = files[norm(p)]
    if not c then error("No such file", 2) end
    return #c
  end
  function fs.getCapacity() return env.capacity end
  function fs.getFreeSpace() return env.capacity - used() end
  function fs.list(p)
    p = norm(p)
    if not dirs[p] then error("Not a directory", 2) end
    local seen, out = {}, {}
    local prefix = p == "" and "" or p .. "/"
    local function add(full)
      if full ~= p and full:sub(1, #prefix) == prefix then
        local name = full:sub(#prefix + 1):match("^[^/]+")
        if name and not seen[name] then seen[name] = true; out[#out + 1] = name end
      end
    end
    for f in pairs(files) do add(f) end
    for d in pairs(dirs) do add(d) end
    table.sort(out)
    return out
  end
  function fs.delete(p)
    p = norm(p)
    files[p] = nil
    if dirs[p] and p ~= "" then
      dirs[p] = nil
      local prefix = p .. "/"
      for f in pairs(files) do if f:sub(1, #prefix) == prefix then files[f] = nil end end
      for d in pairs(dirs) do if d:sub(1, #prefix) == prefix then dirs[d] = nil end end
    end
  end
  function fs.move(a, b)
    a, b = norm(a), norm(b)
    if not fs.exists(a) then error("No such file", 2) end
    if fs.exists(b) then error("File exists", 2) end
    mkdirs(parent(b))
    if files[a] then
      files[b], files[a] = files[a], nil
    else
      local prefix = a .. "/"
      dirs[b], dirs[a] = true, nil
      for f, c in pairs(files) do
        if f:sub(1, #prefix) == prefix then files[b .. "/" .. f:sub(#prefix + 1)] = c; files[f] = nil end
      end
      for d in pairs(dirs) do
        if d:sub(1, #prefix) == prefix then dirs[b .. "/" .. d:sub(#prefix + 1)] = true; dirs[d] = nil end
      end
    end
  end
  function fs.open(p, mode)
    p = norm(p)
    mode = mode:gsub("b", "")
    if mode == "r" then
      local c = files[p]
      if not c then return nil, "No such file" end
      local pos = 1
      return {
        readAll = function() local s = c:sub(pos); pos = #c + 1; return s end,
        read = function(n) n = n or 1; if pos > #c then return nil end
          local s = c:sub(pos, pos + n - 1); pos = pos + n; return s end,
        close = function() end,
      }
    end
    if dirs[p] then return nil, "Cannot write to directory" end
    mkdirs(parent(p))
    local buf = mode == "a" and (files[p] or "") or ""
    local base = used() - #(files[p] or "")
    files[p] = buf
    return {
      write = function(s)
        s = tostring(s)
        if base + #buf + #s > env.capacity then error("Out of space", 2) end
        buf = buf .. s
        files[p] = buf
      end,
      flush = function() end,
      close = function() end,
    }
  end
  fs.combine = function(a, b) return norm(a .. "/" .. b) end
  -- like real CC: the parent of the root is ".."
  fs.getDir = function(p) p = norm(p); if p == "" then return ".." end; return parent(p) end
  env.fs = fs

  env.os = { epoch = function() return now end, clock = function() return now / 1000 end }
  function env.setTime(ms) now = ms end

  local attached, order = {}, {}
  function env.attach(name, ptype, methods)
    if not attached[name] then order[#order + 1] = name end
    attached[name] = { type = ptype, methods = methods }
  end
  local peripheral = {}
  function peripheral.getNames()
    local out = {}
    for _, n in ipairs(order) do out[#out + 1] = n end
    return out
  end
  function peripheral.isPresent(n) return attached[n] ~= nil end
  function peripheral.getType(n) return attached[n] and attached[n].type end
  function peripheral.wrap(n) return attached[n] and attached[n].methods end
  function peripheral.getMethods(n)
    if not attached[n] then return nil end
    local out = {}
    for k in pairs(attached[n].methods) do out[#out + 1] = k end
    table.sort(out)
    return out
  end
  function peripheral.call(n, m, ...) return attached[n].methods[m](...) end
  function peripheral.getName(wrapped)
    for n, a in pairs(attached) do if a.methods == wrapped then return n end end
  end
  function peripheral.find(ptype)
    for _, n in ipairs(order) do
      if attached[n].type == ptype then return attached[n].methods end
    end
  end
  env.peripheral = peripheral

  -- test helper: read a file's whole content (nil if missing)
  function env.read(p) return files[norm(p)] end
  function env.write(p, c) p = norm(p); mkdirs(parent(p)); files[p] = c end

  return env
end

return shim
