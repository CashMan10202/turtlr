-- Small rotating log file. Never throws: a full disk or broken sink must not crash the program.
--   local L = log.new{ fs = fs, path = "/bs/log.txt", level = "info", keepKB = 64, clock = function() return os.epoch("utc") end }
--   L.info("store", "put ok", { key = "a" })
local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

local function clean(v)
  return (tostring(v):gsub("[%c]+", " "))
end

function log.new(opts)
  local fs, path = opts.fs, opts.path
  local min = LEVELS[opts.level or "info"]
  if not min then error("log: unknown level " .. tostring(opts.level), 2) end
  local maxBytes = (opts.keepKB or 64) * 1024
  local clock = opts.clock
  local size = fs.exists(path) and fs.getSize(path) or 0
  local L = {}

  local function write(line)
    if size + #line > maxBytes then
      if fs.exists(path .. ".1") then fs.delete(path .. ".1") end
      if fs.exists(path) then fs.move(path, path .. ".1") end
      size = 0
    end
    local h = fs.open(path, "a")
    h.write(line)
    h.close()
    size = size + #line
  end

  local function emit(level, tag, msg, fields)
    if LEVELS[level] < min then return end
    local ts = clock()
    local parts = { tostring(ts), level:upper(), clean(tag), clean(msg) }
    if fields then
      local keys = {}
      for k in pairs(fields) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do parts[#parts + 1] = clean(k) .. "=" .. clean(fields[k]) end
    end
    pcall(write, table.concat(parts, " ") .. "\n")
    if opts.sink then
      pcall(opts.sink, { ts = ts, level = level, tag = tag, msg = msg, fields = fields })
    end
  end

  for level in pairs(LEVELS) do
    L[level] = function(tag, msg, fields) emit(level, tag, msg, fields) end
  end

  -- Last n lines of the current log file.
  function L.tail(n)
    local h = fs.open(path, "r")
    if not h then return {} end
    local lines = {}
    for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
    h.close()
    local out = {}
    for i = math.max(1, #lines - n + 1), #lines do out[#out + 1] = lines[i] end
    return out
  end

  return L
end

return log
