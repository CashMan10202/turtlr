-- BuildKit release bundle. Drag this file onto a computer, then run:  buildkit
-- It unpacks itself and opens the setup screen (or: buildkit <role> to install without the screen).
local args = { ... }
local F = {}
F["install/install.lua"] = [=[
-- BuildKit installer. Run on the computer you are setting up.
--   install                      (release on a floppy at /disk/buildservice)
--   install <role>               (same, skipping the role menu)
--   install <role> <https url>   (release hosted on the web)
local args = { ... }

-- Find where this installer lives so it can load its helper files from the same release.
local here = fs.getDir(shell.getRunningProgram())      -- .../install
local root = fs.getDir(here)                           -- release root
if here == "" or here == ".." or root == ".." then root = "" end
package.path = "/" .. root .. "/?.lua;" .. package.path

local role, url = args[1], args[2]

-- Web installs start with only this file, so fetch the two helper files it needs first.
if url then
  if not http then error("HTTP is disabled on this server", 0) end
  if url:sub(1, 8) ~= "https://" then error("the address must start with https://", 0) end
end
if url and not fs.exists("/" .. root .. "/install/installer_core.lua") then
  local base = url:sub(-1) == "/" and url or url .. "/"
  for _, path in ipairs({ "install/installer_core.lua", "lib/sha256.lua" }) do
    local res, err = http.get(base .. path)
    if not res then error("cannot download " .. path .. ": " .. tostring(err), 0) end
    local h = fs.open("/bs/.boot/" .. path, "w")
    h.write(res.readAll()); h.close(); res.close()
  end
  package.path = "/bs/.boot/?.lua;" .. package.path
end

local core = require("install.installer_core")
local fetch
if url then
  fetch = core.fetchers.http(http, url)
else
  fetch = core.fetchers.disk(fs, "/" .. root)
end

local src, ferr = fetch("manifest.lua")
if not src then error("cannot read manifest.lua: " .. tostring(ferr), 0) end
local fn, lerr = load(src, "=manifest", "t", {})
if not fn then error("manifest.lua is damaged: " .. tostring(lerr), 0) end
local manifest = fn()

if not role then
  local roles = {}
  for name in pairs(manifest.roles) do roles[#roles + 1] = name end
  table.sort(roles)
  print("BuildKit " .. manifest.version .. " - which role is this computer?")
  for i, name in ipairs(roles) do print(("%2d. %s"):format(i, name)) end
  write("Number: ")
  role = roles[tonumber(read())]
  if not role then error("not a valid choice", 0) end
end

local before = core.installed(fs)
if before and before.role ~= role then
  print("This computer is currently '" .. before.role .. "'. Change it to '" .. role .. "'? (y/n)")
  if read():lower() ~= "y" then return end
end

print("Installing " .. role .. " " .. manifest.version .. " ...")
local ok, err = core.install(fs, fetch, manifest, role, { yield = function() sleep(0) end })
if fs.exists("/bs/.boot") then fs.delete("/bs/.boot") end
if not ok then
  printError("Install failed, nothing was changed: " .. tostring(err))
  return
end
print("Done. Edit /bs/role/config.lua if needed, then reboot.")
if fs.exists("/bs/role/config.lua.new") then
  print("Your config was kept. The new default is in /bs/role/config.lua.new")
end
]=]
F["install/installer_core.lua"] = [=[
-- Installer logic, kept free of screen/keyboard code so it can be tested outside Minecraft.
-- Safety rule: every file is downloaded and hash-checked into /bs/.staging first.
-- Only when ALL files are verified are they moved into place.
local sha256 = require("lib.sha256")

local core = {}

local STAGING = "/bs/.staging"
local MARKER = "/bs/.installing"

local function safeDest(dest)
  if type(dest) ~= "string" or dest:sub(1, 1) ~= "/" then return false end
  for part in dest:gmatch("[^/]+") do
    if part == ".." or part == "." then return false end
  end
  if dest == "/startup.lua" or dest == "/setup.lua" then return true end
  if dest:sub(1, #STAGING) == STAGING then return false end
  return dest:sub(1, 4) == "/bs/" and #dest > 4
end

-- Returns the list of files for a role, or nil plus an error.
function core.plan(manifest, role)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or type(manifest.version) ~= "string" then
    return nil, "manifest is not valid"
  end
  local entries = manifest.roles[role]
  if type(entries) ~= "table" or #entries == 0 then return nil, "unknown role: " .. tostring(role) end
  for _, e in ipairs(entries) do
    if type(e) ~= "table" or type(e.path) ~= "string" or type(e.size) ~= "number"
        or type(e.sha256) ~= "string" or not safeDest(e.dest) then
      return nil, "manifest entry is not valid: " .. tostring(type(e) == "table" and e.path or e)
    end
  end
  return entries
end

core.fetchers = {}

-- Read release files from a folder (a floppy disk).
function core.fetchers.disk(fs, root)
  return function(path)
    local h = fs.open(root .. "/" .. path, "rb")
    if not h then return nil, "cannot read " .. path end
    local data = h.readAll()
    h.close()
    return data
  end
end

-- Download release files from a web address.
function core.fetchers.http(http, baseUrl)
  if baseUrl:sub(-1) ~= "/" then baseUrl = baseUrl .. "/" end
  return function(path)
    local res, err = http.get(baseUrl .. path, nil, true)
    if not res then return nil, "cannot download " .. path .. ": " .. tostring(err) end
    local data = res.readAll()
    res.close()
    return data
  end
end

local function writeFile(fs, path, data)
  local h, err = fs.open(path, "wb")
  if not h then error(tostring(err)) end
  h.write(data)
  h.close()
end

local function isRoleConfig(dest) return dest == "/bs/role/config.lua" end

-- Installs a role. opts.yield (optional) is called between files so long installs do not time out.
-- Returns true, or nil plus an error. On error nothing outside /bs/.staging has changed.
function core.install(fs, fetch, manifest, role, opts)
  local entries, err = core.plan(manifest, role)
  if not entries then return nil, err end
  local yield = opts and opts.yield or function() end

  if fs.exists(STAGING) then fs.delete(STAGING) end
  local need = 0
  for _, e in ipairs(entries) do need = need + e.size end
  if fs.getFreeSpace("/") < need + 1024 then
    return nil, "not enough free space: need " .. (need + 1024) .. " bytes, have " .. fs.getFreeSpace("/")
  end

  -- 1. download + verify everything into staging
  local ok, why = pcall(function()
    for _, e in ipairs(entries) do
      local data, ferr = fetch(e.path)
      if not data then error(ferr or ("cannot fetch " .. e.path), 0) end
      if #data ~= e.size then error("size mismatch: " .. e.path, 0) end
      if sha256.hex(data) ~= e.sha256:lower() then error("hash mismatch: " .. e.path, 0) end
      writeFile(fs, STAGING .. e.dest, data)
      yield()
    end
  end)
  if not ok then
    pcall(fs.delete, STAGING)
    return nil, tostring(why)
  end

  -- 2. swap into place. The marker makes startup refuse to run a half-swapped install.
  writeFile(fs, MARKER, "1")
  for _, e in ipairs(entries) do
    local dest = e.dest
    if isRoleConfig(dest) and fs.exists(dest) then dest = dest .. ".new" end
    if fs.exists(dest) then fs.delete(dest) end
    fs.move(STAGING .. e.dest, dest)
  end
  writeFile(fs, "/bs/.version", ("return { role = %q, version = %q }\n"):format(role, manifest.version))
  fs.delete(STAGING)
  fs.delete(MARKER)
  return true
end

-- Reads /bs/.version. Returns { role, version } or nil.
function core.installed(fs)
  local h = fs.open("/bs/.version", "r")
  if not h then return nil end
  local src = h.readAll()
  h.close()
  local fn = load(src, "=version", "t", {})
  local ok, v = pcall(fn or error)
  if ok and type(v) == "table" then return v end
end

return core
]=]
F["install/keys_core.lua"] = [=[
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
]=]
F["install/mkkeys.lua"] = [=[
-- Creates and installs the secret link keys for the base computers.
--   mkkeys              make new keys for every role onto the floppy (/disk/bskeys/)
--   mkkeys load <role>  copy this computer's keys from the floppy to /bs/keys.lua
-- Make the keys once, load them on every base computer, then lock the floppy away.
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local keys_core = require("install.keys_core")

local args = { ... }
local DISK = "/disk/bskeys"

if args[1] == "load" then
  local role = args[2]
  if not role then error("usage: mkkeys load <role>", 0) end
  local src = DISK .. "/" .. role .. ".lua"
  if not fs.exists(src) then error("no keys for '" .. role .. "' on the floppy (" .. src .. ")", 0) end
  if not keys_core.load(fs, src) then error("the key file on the floppy is damaged", 0) end
  if fs.exists("/bs/keys.lua") then fs.delete("/bs/keys.lua") end
  fs.copy(src, "/bs/keys.lua")
  print("Keys for " .. role .. " installed. Reboot this computer.")
  return
end

if not fs.exists("/disk") then error("put a floppy disk in a drive next to this computer first", 0) end
if fs.exists(DISK) then
  print("This floppy already has keys. Making new ones means EVERY base computer")
  print("must load keys again. Type YES to replace them:")
  if read() ~= "YES" then print("Nothing changed."); return end
  fs.delete(DISK)
end

local crypto = require("lib.crypto")
print("Gathering randomness...")
crypto.initWithTiming()
print("Now mash the keyboard for a few seconds, then press Enter.")
local mash = {}
while true do
  local ev, key = os.pullEvent()
  if ev == "key" then
    if key == keys.enter then break end
    mash[#mash + 1] = key .. ":" .. os.epoch("utc")
  elseif ev == "char" then
    mash[#mash + 1] = key .. os.clock()
  end
end
crypto.mix(table.concat(mash, ","))

local all = keys_core.generate(crypto.random, keys_core.ROLES)
for _, role in ipairs(keys_core.ROLES) do
  local h = fs.open(DISK .. "/" .. role .. ".lua", "w")
  h.write(keys_core.serialise(all[role]))
  h.close()
end
print("Keys written to the floppy for: " .. table.concat(keys_core.ROLES, ", "))
print("On each base computer run:  mkkeys load <role>")
]=]
F["install/setup.lua"] = [=[
-- BuildKit setup screen: click a button (or press its number). The green button is the next step.
-- Start it with:  setup      (or it opens by itself when you run buildkit)
local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
if here == "" or here == ".." or root == ".." then root = "" end
package.path = "/" .. root .. "/?.lua;" .. package.path

local ui = require("install.setup_ui")
local core = require("install.installer_core")
local keys_core = require("install.keys_core")

local W, H = term.getSize()
local colour = term.isColour()
local TOP = 6

local function prog(name) return "/" .. here .. "/" .. name .. ".lua" end

-- where the release files are, if any
local function findRelease()
  for _, dir in ipairs({ "/" .. root, "/bs-release", "/disk/buildservice" }) do
    if fs.exists(dir .. "/manifest.lua") then return dir end
  end
end

local function isBaseRole(role)
  for _, r in ipairs(keys_core.ROLES) do
    if r == role then return true end
  end
  return false
end

local function getState()
  local inst = core.installed(fs)
  local role = inst and inst.role
  return {
    release = findRelease() ~= nil,
    role = role, version = inst and inst.version,
    isBase = role ~= nil and isBaseRole(role),
    hasKeys = fs.exists("/bs/keys.lua"),
    floppy = fs.exists("/disk"),
    floppyKeys = role ~= nil and fs.exists("/disk/bskeys/" .. role .. ".lua"),
  }
end

-- drawing -------------------------------------------------------------------
local function paint(fg, bg)
  if colour then
    term.setTextColour(fg)
    term.setBackgroundColour(bg)
  else
    term.setTextColour(colours.white)
    term.setBackgroundColour(colours.black)
  end
end

local function line(y, text, fg, bg)
  term.setCursorPos(1, y)
  paint(fg or colours.white, bg or colours.black)
  term.write((text .. (" "):rep(W)):sub(1, W))
end

local function clear()
  paint(colours.white, colours.black)
  term.clear()
  term.setCursorPos(1, 1)
end

local function button(r, text, fg, bg)
  term.setCursorPos(r.x, r.y)
  paint(fg, bg)
  term.write((" " .. text .. (" "):rep(W)):sub(1, r.w))
end

-- Wait for a click or a typed character. Returns "click", x, y  or  "char", c.
local function input()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then return "click", b, c end
    if ev == "char" then return "char", a end
  end
end

-- Show a menu and return the chosen item (nil when the user presses q).
-- header: list of { text, colour }. items: list of { label = ..., recommended = bool, ... }.
local function choose(header, items)
  local page = 1
  while true do
    local probe = ui.layout(#items, W, H, TOP)
    local pages = ui.paginate(items, probe.perPage)
    if page > #pages then page = 1 end
    local shown = { table.unpack(pages[page]) }
    if #pages > 1 then shown[#shown + 1] = { label = "More... (" .. page .. "/" .. #pages .. ")", more = true } end
    local L = ui.layout(#shown, W, H, TOP)

    clear()
    for i, h in ipairs(header) do line(i, h[1], h[2]) end
    for i, item in ipairs(shown) do
      local bg = item.recommended and colours.green or (item.more and colours.grey or colours.blue)
      button(L.rect(i), (i <= 9 and i .. " " or "  ") .. item.label, colours.white, bg)
    end
    line(H, "Click, or press a number. q = back", colours.lightGrey)

    local kind, a, b = input()
    local index
    if kind == "click" then
      index = ui.hit(L, #shown, a, b)
    elseif a == "q" then
      return nil
    else
      index = tonumber(a)
    end
    local picked = index and shown[index]
    if picked and picked.more then
      page = page % #pages + 1
    elseif picked then
      return picked
    end
  end
end

-- Show a few lines and an OK button; any click or key continues.
local function message(lines, fg)
  clear()
  local y = 1
  for _, text in ipairs(lines) do
    while #text > 0 and y < H - 1 do
      line(y, text:sub(1, W), fg)
      text = text:sub(W + 1)
      y = y + 1
    end
    if text == "" and y < H - 1 then y = y + 0 end
  end
  button({ x = 2, y = H - 1, w = W - 2 }, "OK", colours.white, colours.blue)
  line(H, "Click or press Space", colours.lightGrey)
  input()
end

-- Run another program full screen, then wait before returning to the menu.
local function run(name, ...)
  clear()
  shell.run(table.concat({ prog(name), ... }, " "))
  paint(colours.yellow, colours.black)
  print("")
  print("Click or press Space to go back")
  input()
end

-- actions -------------------------------------------------------------------
local function header(state)
  local keysText = "not needed"
  if state.isBase then keysText = state.hasKeys and "loaded" or "missing" end
  if not state.role then keysText = "-" end
  local step = ui.nextStep(state)
  return {
    { "BuildKit setup", colours.yellow },
    { "Role: " .. (state.role and (state.role .. " " .. tostring(state.version)) or "not installed") },
    { "Keys: " .. keysText },
    { "Next: " .. (ui.HINTS[step] or ""), colours.lime },
  }
end

local function doInstall()
  local dir = findRelease()
  local src = dir and fs.open(dir .. "/manifest.lua", "r")
  if not src then return message({ "No release files found." }, colours.red) end
  local fn = load(src.readAll(), "=manifest", "t", {})
  src.close()
  local ok, manifest = pcall(fn or error)
  if not ok or type(manifest) ~= "table" or type(manifest.roles) ~= "table" then
    return message({ "The release files are damaged." }, colours.red)
  end
  local roles = {}
  for name in pairs(manifest.roles) do roles[#roles + 1] = name end
  table.sort(roles)
  local items = {}
  for i, name in ipairs(roles) do items[i] = { label = name, role = name } end
  local picked = choose({ { "What is this computer?", colours.yellow },
    { "Release " .. tostring(manifest.version) } }, items)
  if not picked then return end
  clear()
  line(1, "Installing " .. picked.role .. " ...", colours.yellow)
  local done, err = core.install(fs, core.fetchers.disk(fs, dir), manifest, picked.role,
    { yield = function() sleep(0) end })
  if done then
    message({ "Installed: " .. picked.role .. " " .. tostring(manifest.version), "",
      "Follow the green button on the next screen." }, colours.lime)
  else
    message({ "Install failed, nothing was changed:", tostring(err) }, colours.red)
  end
end

local function doVerify()
  local items = { { label = "Quick check", flag = false } }
  items[#items + 1] = { label = "Check + pixel test", flag = "--gfx" }
  if turtle then items[#items + 1] = { label = "Check + area scan", flag = "--scan" } end
  for _, name in ipairs(peripheral.getNames()) do
    local ty = peripheral.getType(name)
    if ty == "nbt_storage" or ty == "nbtStorage" then
      items[#items + 1] = { label = "Check + NBT size (empty NBT only)", flag = "--nbt-write" }
      break
    end
  end
  items[#items + 1] = { label = "Back", back = true }
  local picked = choose({ { "Check this computer", colours.yellow },
    { "Result is saved to" }, { "/verify_report.txt" } }, items)
  if not picked or picked.back then return end
  if picked.flag then run("verify", picked.flag) else run("verify") end
end

local function doGetRelease()
  message({ "This computer has no release files.", "",
    "Drag buildkit.lua from your PC onto this screen, then type:", "", "  buildkit" }, colours.white)
end

-- main loop -----------------------------------------------------------------
while true do
  local state = getState()
  local picked = choose(header(state), ui.menu(state))
  if not picked or picked.id == "exit" then break end
  if picked.id == "install" then doInstall()
  elseif picked.id == "getrelease" then doGetRelease()
  elseif picked.id == "verify" then doVerify()
  elseif picked.id == "mkkeys" then run("mkkeys")
  elseif picked.id == "loadkeys" then run("mkkeys", "load", state.role)
  elseif picked.id == "storetest" then run("storetest")
  elseif picked.id == "reboot" then
    -- free the disk space used by the unpacked release before restarting
    if fs.exists("/bs/.version") and fs.exists("/bs-release") then fs.delete("/bs-release") end
    clear()
    print("Rebooting...")
    os.reboot()
  end
end
clear()
print("Setup closed. Type 'setup' to open it again.")
]=]
F["install/setup_ui.lua"] = [=[
-- Logic for the setup screen, kept separate from drawing so it can be tested outside Minecraft.
local ui = {}

-- What the user should do next. state fields:
--   release (release files are available), role, isBase (role uses the internal network),
--   hasKeys, floppy (a disk is in a drive), floppyKeys (the disk has keys for this role)
function ui.nextStep(s)
  if not s.role then return s.release and "install" or "getrelease" end
  if s.isBase and not s.hasKeys then
    if s.floppyKeys then return "loadkeys" end
    if s.floppy then return "mkkeys" end
    return "needfloppy"
  end
  if s.role == "compute" then return "storetest" end
  if s.isBase then return "reboot" end
  return "verify"
end

ui.HINTS = {
  install = "Pick what this computer is.",
  getrelease = "Release file needed.",
  loadkeys = "Load this computer's keys.",
  mkkeys = "Make keys (first computer only).",
  needfloppy = "Put the key floppy in a drive.",
  storetest = "Test the storage system.",
  reboot = "Reboot to start the program.",
  verify = "Check the mods work here.",
}

-- Buttons for the main menu: the recommended one first (flagged), then the rest.
function ui.menu(s)
  local items = {}
  local function add(id, label, show)
    if show then items[#items + 1] = { id = id, label = label } end
  end
  add("getrelease", "Get the release file", not s.release and not s.role)
  add("install", s.role and "Change role" or "Install a role", s.release)
  add("loadkeys", "Load keys (" .. tostring(s.role) .. ")", s.isBase and s.floppyKeys)
  add("mkkeys", "Make new keys", s.isBase and s.floppy)
  add("verify", "Check this computer", true)
  add("storetest", "Test storage", s.role == "compute" and s.hasKeys)
  add("reboot", "Reboot (start program)", s.role ~= nil)
  add("exit", "Exit", true)
  local nextId = ui.nextStep(s)
  for i, item in ipairs(items) do
    if item.id == nextId then
      table.remove(items, i)
      item.recommended = true
      table.insert(items, 1, item)
      break
    end
  end
  return items
end

-- Where buttons go: one row each from `top` down to the row above the footer,
-- with a blank row between them when there is room.
function ui.layout(count, w, h, top)
  local rows = (h - 1) - top + 1
  local shown = math.min(count, rows)
  local step = (shown * 2 - 1 <= rows) and 2 or 1
  return {
    perPage = rows, step = step, top = top,
    rect = function(i) return { x = 2, y = top + (i - 1) * step, w = w - 2, h = 1 } end,
  }
end

-- Which button (1..count) is at x, y; nil if none.
function ui.hit(L, count, x, y)
  for i = 1, math.min(count, L.perPage) do
    local r = L.rect(i)
    if y == r.y and x >= r.x and x <= r.x + r.w - 1 then return i end
  end
end

-- Split a long list into pages. Lists longer than one page keep a slot free for a "More" button.
function ui.paginate(items, perPage)
  if #items <= perPage then return { { table.unpack(items) } } end
  local pages, size = {}, perPage - 1
  for i = 1, #items, size do
    pages[#pages + 1] = { table.unpack(items, i, math.min(i + size - 1, #items)) }
  end
  return pages
end

return ui
]=]
F["install/storetest.lua"] = [=[
-- In-game check of the storage service. Run on the COMPUTE computer (it has the compute keys):
--   /bs/install/storetest
-- Stores, reads back, lists and deletes test values and prints timings. Uses the key prefix "selftest-".
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local crypto = require("lib.crypto")
local proto = require("lib.proto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local storeclient = require("lib.storeclient")
local keys_core = require("install.keys_core")

local keys, err = keys_core.load(fs, "/bs/keys.lua")
if not keys then error(err, 0) end
if not keys.storage then error("this computer's keys cannot talk to storage (run on COMPUTE)", 0) end
local modem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then modem = peripheral.wrap(name) end
end
if not modem then error("no wireless modem attached", 0) end

print("Gathering randomness...")
if not crypto.ready() then crypto.initWithTiming() end
local function clock() return os.epoch("utc") end
local B = bus.new({ modem = modem, channel = proto.CH.BUS, role = "compute", instance = 99, keys = keys,
  crypto = crypto, clock = clock })
local R = rpc.new({ bus = B, pull = os.pullEvent, startTimer = os.startTimer, queueEvent = os.queueEvent, clock = clock })
local store = storeclient.new({ rpc = R, sleep = sleep })

local failed = 0
local function step(name, fn)
  local start = clock()
  local ok, detail = fn()
  local ms = clock() - start
  if term.isColour() then term.setTextColour(ok and colours.lime or colours.red) end
  write(ok and "[PASS] " or "[FAIL] ")
  term.setTextColour(colours.white)
  print(("%s (%d ms) %s"):format(name, ms, detail and tostring(detail) or ""))
  if not ok then failed = failed + 1 end
end

local function tests()
  local small = "hello " .. clock()
  local big = {}
  for i = 1, 2000 do big[i] = ("%05d:"):format(i) .. string.char(i % 256):rep(44) end
  big = table.concat(big) -- 100 KB including every byte value

  step("health", function()
    local h, e = store.health()
    if not h then return false, e .. " - is a storage manager running and primary?" end
    return true, ("%d devices, %d keys, %d/%d bytes, degraded %d, lost %d")
      :format(h.devices, h.keys, h.used, h.capacity, h.degraded, h.lost)
  end)
  step("put small", function() return store.put("config", "selftest-small", small) end)
  step("get small", function()
    local v, e = store.get("config", "selftest-small")
    if v == small then return true end
    return false, e or "data differs!"
  end)
  step("put 100 KB", function() return store.put("config", "selftest-big", big) end)
  step("get 100 KB", function()
    local v, e = store.get("config", "selftest-big")
    if v == big then return true end
    return false, e or "data differs!"
  end)
  step("list", function()
    local keysFound, e = store.list("config", "selftest-")
    return keysFound and #keysFound == 2, e or (keysFound and #keysFound .. " keys")
  end)
  step("delete", function()
    return store.delete("config", "selftest-small") and store.delete("config", "selftest-big")
  end)
  step("gone after delete", function()
    local _, e = store.get("config", "selftest-small")
    return e == "not_found", e
  end)
  print(failed == 0 and "All storage checks passed." or (failed .. " check(s) failed."))
end

parallel.waitForAny(R.pumpLoop, tests)
]=]
F["install/verify.lua"] = [=[
-- BuildKit verify: checks the mods on this server behave as expected.
--   verify              safe checks only
--   verify --gfx        also draw a pixel test (CC: Graphics)
--   verify --scan       also time a radius-16 Geo Scanner scan (uses turtle fuel)
--   verify --nbt-write  also measure the NBT Storage size limit (ONLY on an empty NBT Storage)
-- Writes the result to /verify_report.txt
local here = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.getDir(here) .. "/?.lua;" .. package.path
local core = require("install.verify_core")

local flags = {}
for _, a in ipairs({ ... }) do
  if a == "--gfx" then flags.gfx = true
  elseif a == "--scan" then flags.scan = true
  elseif a == "--nbt-write" then flags.nbtWrite = true
  else error("unknown option " .. a .. " (use --gfx, --scan, --nbt-write)", 0) end
end

local results = core.runAll({
  _HOST = _HOST, fs = fs, http = http, term = term, peripheral = peripheral, os = os,
  gps = gps, turtle = turtle, shell = shell, flags = flags,
})

local kind = turtle and "turtle" or pocket and "pocket" or "computer"
local header = ("BuildKit verify - %s #%d %s"):format(kind, os.getComputerID(), os.getComputerLabel() or "")
local colour = { PASS = colours.lime, FAIL = colours.red, SKIP = colours.lightGrey }

-- Print a page at a time so nothing scrolls off small screens (turtles, pockets).
local _, height = term.getSize()
local used = 0
local function show(status, text)
  local _, before = term.getCursorPos()
  if status then
    if term.isColour() then term.setTextColour(colour[status] or colours.white) end
    write("[" .. status .. "] ")
    term.setTextColour(colours.white)
  end
  local lines = print(text)
  used = used + lines
  if used >= height - 3 then
    term.setTextColour(colours.yellow)
    write("-- more: press any key --")
    term.setTextColour(colours.white)
    os.pullEvent("key")
    term.clear()
    term.setCursorPos(1, 1)
    used = 0
  end
end

show(nil, header)
for _, r in ipairs(results) do show(r.status, r.id .. ": " .. r.detail) end

local h = fs.open("/verify_report.txt", "w")
h.write(header .. "\n" .. table.concat(core.report(results), "\n") .. "\n")
h.close()
print("Saved to /verify_report.txt")
]=]
F["install/verify_core.lua"] = [=[
-- Checks that the mods on this server behave the way BuildKit expects.
-- Each check returns "PASS", "FAIL" or "SKIP" plus a detail line. Missing hardware is a SKIP.
-- env holds the CC globals (fs, peripheral, os, term, http, gps, turtle, shell, _HOST) and env.flags.
local core = {}

-- Find the first attached peripheral whose type is one of `types`. Returns name, type.
local function find(env, types)
  for _, name in ipairs(env.peripheral.getNames()) do
    local ty = env.peripheral.getType(name)
    for _, want in ipairs(types) do
      if ty == want then return name, ty end
    end
  end
end

local function methods(env, name)
  local list = env.peripheral.getMethods(name) or {}
  local set = {}
  for _, m in ipairs(list) do set[m] = true end
  return set, table.concat(list, ", ")
end

local NBT = { "nbtStorage", "nbt_storage" }
local NBT_READERS = { "load", "read" }
local NBT_WRITERS = { "save", "writeTable", "writeJson" }

local function nbtReader(set)
  for _, m in ipairs(NBT_READERS) do
    if set[m] then return m end
  end
end

local function nbtWriter(set)
  for _, m in ipairs(NBT_WRITERS) do
    if set[m] then return m end
  end
end

-- A peripheral check that only looks at method names.
local function apiCheck(id, desc, types, needAll, needAny)
  return { id = id, desc = desc, run = function(env)
    local name, ty = find(env, types)
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    for _, m in ipairs(needAll) do
      if not set[m] then return "FAIL", "missing " .. m .. "; " .. ty .. " has: " .. listed end
    end
    if needAny then
      local got = false
      for _, m in ipairs(needAny) do got = got or set[m] end
      if not got then
        return "FAIL", "needs one of " .. table.concat(needAny, "/") .. "; " .. ty .. " has: " .. listed
      end
    end
    return "PASS", ty .. ": " .. listed
  end }
end

core.checks = {
  { id = "cc.version", desc = "CC: Tweaked 1.112 or newer", run = function(env)
    local major, minor = tostring(env._HOST):match("ComputerCraft (%d+)%.(%d+)")
    if not major then return "FAIL", "cannot read version from: " .. tostring(env._HOST) end
    major, minor = tonumber(major), tonumber(minor)
    if major > 1 or (major == 1 and minor >= 112) then return "PASS", env._HOST end
    return "FAIL", "too old: " .. env._HOST
  end },

  { id = "fs.capacity", desc = "Disk space on this computer", run = function(env)
    local cap, free = env.fs.getCapacity("/"), env.fs.getFreeSpace("/")
    if type(cap) ~= "number" then return "PASS", "unlimited" end
    return cap >= 500000 and "PASS" or "FAIL", cap .. " bytes total, " .. tostring(free) .. " free"
  end },

  { id = "http", desc = "HTTP enabled (needed for web installs and INGEST)", run = function(env)
    if env.http then return "PASS", "enabled" end
    return "FAIL", "http is disabled in the server config"
  end },

  { id = "gfx", desc = "CC: Graphics pixel mode (--gfx to draw a test)", run = function(env)
    local term = env.term
    if not term then return "SKIP", "no terminal" end
    if not term.setGraphicsMode then return "FAIL", "not available here; the teletext renderer will be used" end
    if not env.flags.gfx then return "PASS", "setGraphicsMode exists (run with --gfx to test drawing)" end
    local ok, err = pcall(function()
      term.setGraphicsMode(1)
      for i = 0, 15 do term.setPixel(i, i, 2 ^ (i % 16)) end
    end)
    pcall(term.setGraphicsMode, 0)
    if not ok then return "FAIL", "drawing failed: " .. tostring(err) end
    return "PASS", "drew 16 pixels and switched back"
  end },

  { id = "nbt.type", desc = "NBT Storage attached", run = function(env)
    local name, ty = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    local _, listed = methods(env, name)
    return "PASS", "type " .. ty .. "; methods: " .. listed
  end },

  { id = "nbt.api", desc = "NBT Storage has read + write methods", run = function(env)
    local name, ty = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    local reader, writer = nbtReader(set), nbtWriter(set)
    if reader and writer then return "PASS", reader .. " + " .. writer end
    return "FAIL", ty .. " has: " .. listed
  end },

  { id = "nbt.size", desc = "NBT Storage size limit (--nbt-write, device must be empty)", run = function(env)
    local name = find(env, NBT)
    if not name then return "SKIP", "none attached" end
    if not env.flags.nbtWrite then return "SKIP", "run with --nbt-write on an EMPTY device to measure" end
    local dev = env.peripheral.wrap(name)
    local set = methods(env, name)
    local reader, writer = nbtReader(set), nbtWriter(set)
    if not (reader and writer) then return "FAIL", "no usable read/write methods" end
    local current = dev[reader]()
    if type(current) == "table" and next(current) ~= nil then return "SKIP", "device is not empty; not touching it" end
    -- IMPORTANT: one NBT string over 65535 bytes crashes the server (Advanced Peripherals bug),
    -- so the test data is written as many pieces of at most 60000 characters.
    local PIECE, MOST = 60000, 1100000
    local full = 0 -- number of full pieces known to fit
    local function try(extra)
      local tbl, json = {}, {}
      for i = 1, full do tbl["d" .. i] = ("x"):rep(PIECE) end
      if extra > 0 then tbl["d" .. (full + 1)] = ("x"):rep(extra) end
      local arg = tbl
      if writer == "writeJson" then
        for k, v in pairs(tbl) do json[#json + 1] = '"' .. k .. '":"' .. v .. '"' end
        arg = "{" .. table.concat(json, ",") .. "}"
      end
      local ok, res = pcall(dev[writer], arg)
      if not ok or res == false then return false end
      -- do not trust the return value: read it back and see whether it really was stored
      local back = dev[reader]()
      if type(back) ~= "table" then return false end
      for k, v in pairs(tbl) do
        if type(back[k]) ~= "string" or #back[k] ~= #v then return false end
      end
      return true
    end
    if not try(16) then return "FAIL", writer .. " refused even 16 characters" end
    while (full + 1) * PIECE <= MOST and try(PIECE) do full = full + 1 end
    local lo, hi = 0, PIECE -- how much of one more piece fits: lo fits, hi does not
    if (full + 1) * PIECE > MOST then
      hi = 0
    else
      while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if try(mid) then lo = mid else hi = mid end
      end
    end
    pcall(dev[writer], writer == "writeJson" and "{}" or {})
    return "PASS", ("about %d characters total, in pieces of up to %d (via %s/%s)")
      :format(full * PIECE + lo, PIECE, reader, writer)
  end },

  { id = "geo.api", desc = "Geo Scanner (--scan to time a radius-16 scan)", run = function(env)
    local name, ty = find(env, { "geoScanner", "geo_scanner" })
    if not name then return "SKIP", "none attached" end
    local set, listed = methods(env, name)
    -- the method is scanBlocks on newer Advanced Peripherals, scan on older ones
    local method = set.scanBlocks and "scanBlocks" or set.scan and "scan"
    if not method then return "FAIL", ty .. " has no scan method; methods: " .. listed end
    if not env.flags.scan then return "PASS", ty .. " (" .. method .. "): " .. listed end
    local start = env.os.epoch("utc")
    local blocks, err = env.peripheral.call(name, method, 16)
    local ms = env.os.epoch("utc") - start
    if type(blocks) ~= "table" then return "FAIL", method .. "(16) failed: " .. tostring(err) end
    local sample = blocks[1] and blocks[1].name or "?"
    return "PASS", ("%s(16): %d blocks in %d ms; first: %s"):format(method, #blocks, ms, tostring(sample))
  end },

  apiCheck("me.api", "ME Bridge can list and craft items", { "meBridge", "me_bridge" },
    { "craftItem" }, { "listItems", "getItems" }),

  apiCheck("pd.api", "Player Detector can find nearby players", { "playerDetector", "player_detector" },
    { "getPlayersInRange" }, { "getPlayerPos", "getPlayer" }),

  { id = "modem", desc = "Modems attached", run = function(env)
    local found = {}
    for _, name in ipairs(env.peripheral.getNames()) do
      if env.peripheral.getType(name) == "modem" then
        found[#found + 1] = name .. (env.peripheral.call(name, "isWireless") and " (wireless/ender)" or " (wired)")
      end
    end
    if #found == 0 then return "SKIP", "none attached" end
    return "PASS", table.concat(found, ", ")
  end },

  { id = "gps", desc = "GPS position fix", run = function(env)
    if not env.gps then return "SKIP", "no gps API or no modem" end
    local x, y, z = env.gps.locate(2)
    if not x then return "FAIL", "no fix: need 4 GPS hosts in range" end
    return "PASS", ("at %s, %s, %s"):format(x, y, z)
  end },

  { id = "turtle.equip", desc = "Turtle can swap tools", run = function(env)
    if not env.turtle then return "SKIP", "not a turtle" end
    if env.turtle.equipLeft and env.turtle.equipRight then return "PASS", "equipLeft/equipRight exist" end
    return "FAIL", "equip functions missing"
  end },

  { id = "inv.generic", desc = "Turtle can read the block in front (chest, backpack, machine)", run = function(env)
    if not env.turtle then return "SKIP", "not a turtle" end
    local ty = env.peripheral.getType("front")
    if not ty then return "SKIP", "nothing readable in front; place a chest there and re-run" end
    local set = methods(env, "front")
    if not set.list then return "FAIL", ty .. " has no list method" end
    local n = 0
    for _ in pairs(env.peripheral.call("front", "list")) do n = n + 1 end
    return "PASS", ty .. ": " .. n .. " used slots"
  end },

  { id = "secureboot", desc = "CCSecureBoot installed (lock test is manual)", run = function(env)
    if not env.shell then return "SKIP", "no shell" end
    if env.shell.resolveProgram("enroll-secure-boot") then
      return "PASS", "enroll-secure-boot found; still test by hand that a locked device has no shell"
    end
    return "FAIL", "enroll-secure-boot program not found"
  end },
}

-- Runs every check. A check that throws becomes a FAIL; the rest still run.
function core.runAll(env)
  env.flags = env.flags or {}
  local results = {}
  for i, c in ipairs(core.checks) do
    local ok, status, detail = pcall(c.run, env)
    if not ok then status, detail = "FAIL", "error: " .. tostring(status) end
    results[i] = { id = c.id, desc = c.desc, status = status, detail = tostring(detail or "") }
  end
  return results
end

function core.report(results)
  local lines = {}
  for i, r in ipairs(results) do
    lines[i] = ("[%s] %-12s %s -- %s"):format(r.status, r.id, r.desc, r.detail)
  end
  return lines
end

return core
]=]
F["lib/base64.lua"] = [=[
-- Base64 (RFC 4648). Used to store arbitrary bytes as plain text inside NBT Storage blocks.
local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  local c = ALPHABET:sub(i, i)
  enc[i - 1] = c
  dec[c:byte()] = i - 1
end

local floor, char, byte = math.floor, string.char, string.byte

function base64.encode(s)
  local out, n = {}, 0
  for i = 1, #s - 2, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + b * 256 + c
    n = n + 1
    out[n] = enc[floor(v / 262144)] .. enc[floor(v / 4096) % 64] .. enc[floor(v / 64) % 64] .. enc[v % 64]
  end
  local rest = #s % 3
  if rest == 1 then
    local v = byte(s, #s) * 16
    out[n + 1] = enc[floor(v / 64)] .. enc[v % 64] .. "=="
  elseif rest == 2 then
    local a, b = byte(s, #s - 1, #s)
    local v = (a * 256 + b) * 4
    out[n + 1] = enc[floor(v / 4096)] .. enc[floor(v / 64) % 64] .. enc[v % 64] .. "="
  end
  return table.concat(out)
end

-- Returns the bytes, or nil if the text is not valid base64.
function base64.decode(s)
  if type(s) ~= "string" or #s % 4 ~= 0 then return nil end
  local out, n = {}, 0
  local last = #s - 3
  for i = 1, #s, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    local va, vb, vc, vd = dec[a], dec[b], dec[c], dec[d]
    if not va or not vb then return nil end
    n = n + 1
    if vc and vd then
      local v = va * 262144 + vb * 4096 + vc * 64 + vd
      out[n] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
    else
      -- padding is only allowed in the final group
      if i ~= last or d ~= 61 then return nil end
      if c == 61 then
        out[n] = char(va * 4 + floor(vb / 16))
      elseif vc then
        local v = va * 4096 + vb * 64 + vc
        out[n] = char(floor(v / 1024), floor(v / 4) % 256)
      else
        return nil
      end
    end
  end
  return table.concat(out)
end

return base64
]=]
F["lib/bus.lua"] = [=[
-- Encrypted internal bus between base computers.
-- Every frame is sealed with a key shared by exactly two roles, and carries a counter that
-- only ever goes up, so recorded frames cannot be replayed.
--
--   local B = bus.new{ modem = modem, channel = 4210, role = "compute", instance = 1,
--                      keys = { storage = <32 bytes>, ... }, crypto = crypto, clock = function() return os.epoch("utc") end }
--   B.send("storage", { m = "get", key = "a" })
--   local got = B.receive(channel, payload)   -- from a modem_message event; got = { src, instance, msg }
local codec = require("lib.codec")
local S = require("lib.schema")

local bus = {}

bus.MAX_PAYLOAD = 65536
bus.SKEW_MS = 120000
local SEQ = 4096 -- counter = milliseconds * SEQ + sequence

local frameSpec = S.map({
  s = S.str(16, "^[a-z]+$"),         -- sender role
  i = S.int(0, 255),                 -- sender instance
  d = S.str(16, "^[a-z]+$"),         -- destination role
  c = S.int(1, 2 ^ 53),              -- counter
  p = S.bytes(bus.MAX_PAYLOAD + 64), -- sealed payload
})

function bus.new(opts)
  local modem, channel, role, instance = opts.modem, opts.channel, opts.role, opts.instance or 1
  local keys, crypto, clock = opts.keys, opts.crypto, opts.clock
  local lastSent = 0
  local lastSeen = {} -- "role:instance" -> highest counter accepted
  local B = { role = role, instance = instance, channel = channel }

  modem.open(channel)

  -- Returns true, or nil plus "no_key" / "bad_msg" / "too_big".
  function B.send(dst, msg)
    local key = keys[dst]
    if not key then return nil, "no_key" end
    local ok, plain = pcall(codec.encode, msg)
    if not ok then return nil, "bad_msg" end
    if #plain > bus.MAX_PAYLOAD then return nil, "too_big" end
    local counter = math.max(clock() * SEQ, lastSent + 1)
    lastSent = counter
    local sealed = crypto.seal(key, counter, plain, role .. "|" .. instance .. "|" .. dst)
    modem.transmit(channel, channel, codec.encode({ s = role, i = instance, d = dst, c = counter, p = sealed }))
    return true
  end

  -- Returns { src, instance, msg }, or nil plus the reason the frame was dropped.
  function B.receive(ch, payload)
    if ch ~= channel then return nil, "not_for_me" end
    local frame = codec.decode(payload, { maxItems = 16 })
    if type(frame) ~= "table" or not S.check(frameSpec, frame) then return nil, "bad_frame" end
    if frame.d ~= role then return nil, "not_for_me" end
    local key = keys[frame.s]
    if not key then return nil, "no_key" end
    local plain = crypto.open(key, frame.c, frame.p, frame.s .. "|" .. frame.i .. "|" .. frame.d)
    if not plain then return nil, "bad_auth" end
    -- authenticated from here on
    local who = frame.s .. ":" .. frame.i
    if frame.c <= (lastSeen[who] or 0) then return nil, "replay" end
    local age = clock() - math.floor(frame.c / SEQ)
    if age > bus.SKEW_MS or age < -bus.SKEW_MS then return nil, "stale" end
    local msg = codec.decode(plain)
    if type(msg) ~= "table" then return nil, "bad_frame" end
    lastSeen[who] = frame.c
    return { src = frame.s, instance = frame.i, msg = msg }
  end

  return B
end

return bus
]=]
F["lib/codec.lua"] = [=[
-- Strict binary encoder/decoder for protocol messages.
-- Supports only: booleans, integers (|n| <= 2^53), strings, arrays, and maps with string keys.
-- decode() never throws and never executes anything, so it is safe on untrusted bytes.
--
-- Wire format: one tag byte, then the payload.
--   0x00 false | 0x01 true
--   0x02 integer >= 0: varint | 0x06 integer < 0: varint of the magnitude
--   0x03 string:  varint length, bytes
--   0x04 array:   varint count, items
--   0x05 map:     varint count, (varint key length, key bytes, value) pairs, keys sorted
local codec = {}

local MAX_INT = 2 ^ 53
local floor, char, byte = math.floor, string.char, string.byte

local function putVarint(out, n)
  while n >= 128 do
    out[#out + 1] = char(n % 128 + 128)
    n = floor(n / 128)
  end
  out[#out + 1] = char(n)
end

local function putString(out, s)
  putVarint(out, #s)
  out[#out + 1] = s
end

local function enc(out, v, depth)
  local tv = type(v)
  if tv == "boolean" then
    out[#out + 1] = v and "\1" or "\0"
  elseif tv == "number" then
    if v ~= v or v ~= floor(v) or v > MAX_INT or v < -MAX_INT then
      error("codec: number is not a safe integer: " .. tostring(v), 0)
    end
    out[#out + 1] = v >= 0 and "\2" or "\6"
    putVarint(out, v >= 0 and v or -v)
  elseif tv == "string" then
    out[#out + 1] = "\3"
    putString(out, v)
  elseif tv == "table" then
    if depth > 64 then error("codec: table nested too deeply", 0) end
    local n, strKeys = 0, {}
    for k in pairs(v) do
      n = n + 1
      if type(k) == "string" then strKeys[#strKeys + 1] = k end
    end
    if #strKeys == 0 then
      -- array (an empty table is an empty array)
      if n ~= #v then error("codec: array has holes or non-string keys", 0) end
      out[#out + 1] = "\4"
      putVarint(out, n)
      for i = 1, n do enc(out, v[i], depth + 1) end
    else
      if #strKeys ~= n then error("codec: table mixes string and non-string keys", 0) end
      table.sort(strKeys)
      out[#out + 1] = "\5"
      putVarint(out, n)
      for i = 1, n do
        putString(out, strKeys[i])
        enc(out, v[strKeys[i]], depth + 1)
      end
    end
  else
    error("codec: cannot encode a " .. tv, 0)
  end
end

function codec.encode(value)
  local out = {}
  enc(out, value, 1)
  return table.concat(out)
end

-- Decoder state is passed explicitly: s (input), st.pos, st.items (budget left).
local function getVarint(s, st)
  local n, mul = 0, 1
  for i = 1, 8 do
    local b = byte(s, st.pos)
    if not b then return nil, "truncated varint" end
    st.pos = st.pos + 1
    if b < 128 then
      n = n + b * mul
      if n > MAX_INT then return nil, "varint too large" end
      return n
    end
    n = n + (b - 128) * mul
    mul = mul * 128
    if i == 8 then return nil, "varint too long" end
  end
end

local function getString(s, st)
  local len, err = getVarint(s, st)
  if not len then return nil, err end
  if len > #s - st.pos + 1 then return nil, "string length exceeds input" end
  local v = s:sub(st.pos, st.pos + len - 1)
  st.pos = st.pos + len
  return v
end

local function dec(s, st, depth)
  st.items = st.items - 1
  if st.items < 0 then return nil, "too many items" end
  local tag = byte(s, st.pos)
  if not tag then return nil, "truncated" end
  st.pos = st.pos + 1
  if tag == 0 then return false end
  if tag == 1 then return true end
  if tag == 2 or tag == 6 then
    local n, err = getVarint(s, st)
    if not n then return nil, err end
    if tag == 2 then return n end
    if n == 0 then return nil, "negative zero" end
    return -n
  end
  if tag == 3 then return getString(s, st) end
  if tag == 4 or tag == 5 then
    if depth > st.maxDepth then return nil, "nested too deeply" end
    local count, err = getVarint(s, st)
    if not count then return nil, err end
    -- every item needs at least one byte, so a count beyond the remaining input is a lie
    if count > #s - st.pos + 1 then return nil, "count exceeds input" end
    local t = {}
    if tag == 4 then
      for i = 1, count do
        local v, e = dec(s, st, depth + 1)
        if v == nil then return nil, e or "bad item" end
        t[i] = v
      end
    else
      for _ = 1, count do
        local k, e = getString(s, st)
        if not k then return nil, e end
        if t[k] ~= nil then return nil, "duplicate key" end
        local v, e2 = dec(s, st, depth + 1)
        if v == nil then return nil, e2 or "bad value" end
        t[k] = v
      end
    end
    return t
  end
  return nil, "unknown tag " .. tag
end

-- Returns value, or nil plus an error string. Note: a decoded `false` returns false with no error.
function codec.decode(s, opts)
  if type(s) ~= "string" then return nil, "input is not a string" end
  local st = { pos = 1, items = opts and opts.maxItems or 4096, maxDepth = opts and opts.maxDepth or 8 }
  local v, err = dec(s, st, 1)
  if v == nil then return nil, err or "decode failed" end
  if st.pos <= #s then return nil, "trailing bytes" end
  return v
end

return codec
]=]
F["lib/config.lua"] = [=[
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
]=]
F["lib/config_specs.lua"] = [=[
-- What each role's config.lua may contain, with ranges and defaults.
local S = require("lib.schema")
local proto = require("lib.proto")

local function def(spec, default) spec.default = default; return spec end

local function logSpec()
  return S.map({}, {
    level = S.enum({ "debug", "info", "warn", "error" }, "info"),
    keepKB = S.int(8, 512, 64),
  })
end

local function rate(burst, perMinute)
  return S.map({}, { burst = S.int(1, 1000, burst), perMinute = S.int(1, 100000, perMinute) })
end

local function common(extra)
  extra.log = logSpec()
  extra.heartbeatSecs = S.int(1, 60, 5)
  return S.map({}, extra)
end

local worldBox = S.array(S.int(-30000000, 30000000), 6)

local specs = {}

specs.storage = common({
  id = S.int(1, 16, 1),
  replicas = S.int(1, 4, 2),
  shardBytes = S.int(1024, 900000, 40000), -- values above 45000 are treated as 45000
  deviceMaxBytes = S.int(65536, 16000000, 1000000),
  scrubMinutes = S.int(1, 1440, 30),
})

specs.compute = common({
  limits = S.map({}, {
    jobsActive = S.int(1, 100, proto.LIMITS.jobsActive),
    jobBlocks = S.int(1, 1000000, proto.LIMITS.jobBlocks),
    uploadBytes = S.int(1024, 262144, proto.LIMITS.uploadBytes),
    schematicQuota = S.int(1024, 2 ^ 31, proto.LIMITS.schematicQuota),
  }),
  turtleMax = proto.TURTLE_LIMITS,
  noBuild = S.array(worldBox, 64),
  priorities = S.array(S.map({ player = S.str(16), weight = S.int(1, 10) }), 64),
  replaceable = S.array(S.id(), 128),
  marker = def(S.id(), "minecraft:lime_wool"),
  level4 = S.bool(false),
  quoteMinutes = S.int(1, 1440, 15),
})

specs.incoming = common({
  frameMax = S.int(512, 8192, proto.LIMITS.frameMax),
  clockSkewSecs = S.int(5, 600, 120),
  rate = rate(5, 60),
  workerRate = rate(20, 600),
})

specs.outgoing = common({
  frameMax = S.int(512, 8192, proto.LIMITS.frameMax),
  queueMax = S.int(8, 4096, 256),
})

specs.register = common({
  owner = def(S.str(16), "CHANGE_ME"),
  detectRange = S.int(1, 16, 3),
})

specs.ingest = common({
  allowHosts = S.array(S.str(64, "^[a-z0-9.-]+$"), 32),
  maxBytes = S.int(1024, 262144, 262144),
  maxInflated = S.int(1024, 16777216, 4194304),
  maxDim = S.int(1, 64, 64),
  timeoutSecs = S.int(1, 120, 20),
  maxRedirects = S.int(0, 5, 2),
})

specs.monitor = common({
  pinRequired = S.bool(true),
  alarmSide = S.enum({ "none", "top", "bottom", "left", "right", "front", "back" }, "none"),
  speaker = S.bool(true),
  refreshMs = S.int(100, 5000, 500),
})

specs.worker = common({
  scanRadius = S.int(1, 24, proto.LIMITS.scanRadius),
  statusSecs = S.int(1, 60, 5),
})

specs.pocket = common({
  theme = S.enum({ "dark", "light" }, "dark"),
  renderer = S.enum({ "auto", "gfx", "teletext", "text" }, "auto"),
  animations = S.bool(true),
})

specs.gps = S.map({}, {
  set = S.bool(false),
  x = S.int(-30000000, 30000000, 0),
  y = S.int(-64, 320, 0),
  z = S.int(-30000000, 30000000, 0),
})

return specs
]=]
F["lib/crypto.lua"] = [=[
-- Thin wrapper around the vendored ccryptolib, so the rest of the code uses a few simple calls.
--   hash  = BLAKE3            (integrity checks)
--   seal  = ChaCha20-Poly1305 (encrypt + authenticate with a shared 32-byte key)
local random = require("ccryptolib.random")
local blake3 = require("ccryptolib.blake3")
local aead = require("ccryptolib.aead")

local crypto = {}

-- Seed the random generator. Call once at program start with at least 32 bytes of unpredictable data.
function crypto.init(seed)
  if type(seed) ~= "string" or #seed < 32 then error("crypto.init needs a seed of at least 32 bytes", 2) end
  random.init(seed)
end

-- Seed from tiny timing differences on this computer (works in-game without any network).
function crypto.initWithTiming() random.initWithTiming() end

function crypto.ready() return random.isInit() end

-- Stir extra unpredictable data (e.g. keystroke timings) into the generator.
function crypto.mix(data) random.mix(data) end

function crypto.random(n)
  if not random.isInit() then error("crypto.random used before crypto.init", 2) end
  return random.random(n)
end

function crypto.hash(data) return blake3.digest(data) end

function crypto.hex(bytes)
  return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

function crypto.hashHex(data) return crypto.hex(blake3.digest(data)) end

-- Derive a 32-byte key from key material; different context strings give unrelated keys.
function crypto.kdf(context, material) return blake3.deriveKey(context)(material) end

-- The 12-byte nonce is the counter, little-endian. A counter must never repeat for one key.
local function nonce(counter)
  local out = {}
  for i = 1, 12 do
    out[i] = string.char(counter % 256)
    counter = math.floor(counter / 256)
  end
  return table.concat(out)
end

-- Returns ciphertext followed by a 16-byte tag.
function crypto.seal(key, counter, plaintext, aad)
  local ct, tag = aead.encrypt(key, nonce(counter), plaintext, aad or "")
  return ct .. tag
end

-- Returns the plaintext, or nil if anything was changed or the key/counter/aad do not match.
function crypto.open(key, counter, sealed, aad)
  if type(sealed) ~= "string" or #sealed < 16 or type(key) ~= "string" or #key ~= 32 then return nil end
  if type(counter) ~= "number" or counter < 0 then return nil end
  local ok, plain = pcall(aead.decrypt, key, nonce(counter), sealed:sub(-16), sealed:sub(1, -17), aad or "")
  if ok then return plain end
  return nil
end

return crypto
]=]
F["lib/log.lua"] = [=[
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
]=]
F["lib/proto.lua"] = [=[
-- Protocol v1: channels, limits, and the exact shape of every message.
-- Anything not described here is rejected. See docs/protocol.md (generated from this file).
local S = require("lib.schema")

local proto = {}

proto.VERSION = 1
proto.CH = { IN = 4201, OUT = 4202, BUS = 4210, TEL = 4211 }

proto.LIMITS = {
  frameDefault = 2048,      -- bytes, normal max frame
  frameMax = 8192,          -- bytes, hard max (uploads, surveys, layers)
  jobsActive = 3,           -- per player
  jobBlocks = 20000,        -- per job
  uploadBytes = 262144,     -- per uploaded file
  schematicQuota = 2097152, -- bytes stored per player
  areaW = 48, areaD = 48, areaH = 64,
  scanRadius = 16,
}

-- Shared pieces ------------------------------------------------------------
local job, ref = S.tok(24), S.tok(24)
local coord = S.int(-64, 64)
local count = S.int(0, 10000000)
local box = S.array(coord, 6) -- x1,y1,z1,x2,y2,z2 relative to the turtle's start

-- Limits a player sets for their turtle. The owner's config caps every one of them.
proto.TURTLE_LIMITS = S.map({}, {
  w = S.int(1, 48, 16),              -- work area width (x), centred on the turtle
  d = S.int(1, 48, 16),              -- work area depth (z)
  up = S.int(0, 64, 16),             -- blocks above the turtle
  down = S.int(0, 64, 4),            -- blocks below the turtle
  take = S.enum({ "none", "marked", "all" }, "marked"), -- which containers it may take from
  mine = S.bool(false),              -- may it mine ores/stone
  mineMax = S.int(0, 4096, 256),     -- most blocks it may mine
  chop = S.bool(false),              -- may it cut trees
  machines = S.bool(false),          -- may it use machines it finds
  me = S.bool(false),                -- may it attach to an ME network
  fuelReserve = S.int(0, 20000, 500),-- stop and ask when fuel drops below this
  maxMinutes = S.int(1, 1440, 240),  -- give up after this long
  keepOut = S.array(box, 8),         -- boxes it must never enter
})

local shape = S.map({
  kind = S.enum({ "box", "walls", "floor", "cylinder", "tube", "sphere", "dome", "pyramid" }),
  w = S.int(1, 64), h = S.int(1, 64), d = S.int(1, 64),
  block = S.id(),
}, { hollow = S.bool() })

local itemCount = S.map({ id = S.id(), n = count })
local jobState = S.enum({ "quoted", "awaiting_turtle", "survey", "plan", "confirm_plan", "gather", "process",
  "stockpile", "build", "done", "failed", "cancelled" })
local stage = S.enum({ "survey", "gather", "process", "stockpile", "build", "idle" })

-- One step the turtle runs. Fields beyond seq/op depend on the op.
local opSpec = S.map({
  seq = S.int(1, 2147483647),
  op = S.enum({ "goto", "scan", "inspect_inv", "pull", "push", "dig_at", "place_at", "craft", "smelt_start",
    "smelt_collect", "machine_put", "machine_take", "equip", "refuel", "wait", "me_attach", "me_take" }),
}, {
  x = coord, y = coord, z = coord,
  id = S.id(), n = S.int(1, 4096), slot = S.int(1, 16),
  side = S.enum({ "front", "top", "bottom" }),
  tool = S.enum({ "pick", "craft", "scan" }),
  grid = S.array(S.int(0, 16), 9), -- crafting grid: inventory slot per cell, 0 = empty
  r = S.int(1, 24), secs = S.int(1, 600),
})

-- Requests -----------------------------------------------------------------
proto.requests = {
  -- pocket
  ["hello"] = S.map({ client = S.str(16), caps = S.int(0, 7) }),
  ["shape.preview"] = S.map({ shape = shape }),
  ["job.quote"] = S.map({ src = S.enum({ "shape", "lib", "import" }) }, { shape = shape, ref = ref }),
  ["job.confirm"] = S.map({ job = job, quote = S.tok(24) }),
  ["job.cancel"] = S.map({ job = job }),
  ["job.list"] = S.map({ page = S.int(0, 100) }),
  ["job.status"] = S.map({ job = job }),
  ["job.area"] = S.map({ job = job, limits = proto.TURTLE_LIMITS }),
  ["job.plan"] = S.map({ job = job, page = S.int(0, 500) }),
  ["job.approve"] = S.map({ job = job, plan = S.tok(24) }),
  ["lib.list"] = S.map({ page = S.int(0, 500) }),
  ["lib.get_thumb"] = S.map({ ref = ref }),
  ["acct.get"] = S.map({}),
  ["upload.begin"] = S.map({ name = S.str(48, "^[A-Za-z0-9_. -]+$"), size = S.int(1, 262144), sha = S.hex(64),
    chunks = S.int(1, 1024) }),
  ["upload.chunk"] = S.map({ up = S.tok(24), seq = S.int(0, 1023), data = S.bytes(1024), sum = S.hex(16) }),
  ["upload.end"] = S.map({ up = S.tok(24) }),
  ["import.link"] = S.map({ url = S.str(256, "^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%%?&=+-]*$") }),
  ["import.status"] = S.map({ ref = ref }),
  ["rekey"] = S.map({ sign = S.bytes(32), kx = S.bytes(32) }),
  -- worker turtle
  ["w.claim"] = S.map({ fuel = S.int(0, 10000000), slots = S.int(0, 16) }),
  -- pts: each int packs a block: (((x+64)*129 + (y+64))*129 + (z+64))*256 + (index into pal - 1)
  ["w.survey"] = S.map({ job = job, seq = S.int(0, 100000), last = S.bool(), pal = S.array(S.id(), 128),
    pts = S.array(S.int(0, 549552383), 1200) }),
  ["w.inv"] = S.map({ job = job, x = coord, y = coord, z = coord, kind = S.id(),
    items = S.array(itemCount, 128) }),
  ["w.ops"] = S.map({ job = job, after = S.int(0, 2147483647) }),
  ["w.result"] = S.map({ job = job, seq = S.int(1, 2147483647), ok = S.bool() },
    { code = S.enum({ "blocked", "missing", "full", "no_fuel", "no_tool", "out_of_area", "bad_op" }), n = count }),
  ["w.layer"] = S.map({ job = job, y = S.int(0, 255), part = S.int(0, 255) }),
  ["w.progress"] = S.map({ job = job, stage = stage, placed = count, fuel = S.int(0, 10000000),
    x = coord, y = coord, z = coord }),
  ["w.fault"] = S.map({ job = job, code = S.enum({ "blocked", "lost", "no_fuel", "missing", "full", "no_tool",
    "out_of_area", "protected" }), x = coord, y = coord, z = coord }, { id = S.id() }),
  ["w.done"] = S.map({ job = job, placed = count }),
}

-- Rules a plain field list cannot express.
local extra = {
  ["job.quote"] = function(b)
    if b.src == "shape" then
      if not b.shape or b.ref then return "b: src=shape needs shape and no ref" end
    elseif not b.ref or b.shape then
      return "b: src=" .. b.src .. " needs ref and no shape"
    end
  end,
}

-- Responses ----------------------------------------------------------------
local mats = S.array(itemCount, 64)
local dim = S.int(1, 64)

proto.responses = {
  ["hello"] = S.map({ server = S.str(16), minClient = S.str(16), time = S.int(0, 2 ^ 53),
    state = S.enum({ "ok", "maintenance" }) }),
  ["shape.preview"] = S.map({ w = dim, h = dim, d = dim, count = count, mats = mats }),
  ["job.quote"] = S.map({ quote = S.tok(24), count = count, mats = mats, raw = mats, hand = count,
    eta = S.int(0, 10000000), queue = S.int(0, 10000), turtles = S.int(1, 8), expires = S.int(0, 2 ^ 53) }),
  ["job.confirm"] = S.map({ job = job, state = jobState }),
  ["job.cancel"] = S.map({ job = job, state = jobState }),
  ["job.list"] = S.map({ jobs = S.array(S.map({ job = job, state = jobState, pct = S.int(0, 100),
    name = S.str(32) }), 10), more = S.bool() }),
  ["job.status"] = S.map({ job = job, state = jobState, pct = S.int(0, 100), eta = S.int(0, 10000000),
    placed = count, total = count, queue = S.int(0, 10000), need = S.array(itemCount, 32) }),
  ["job.area"] = S.map({ job = job, limits = proto.TURTLE_LIMITS }),
  ["job.plan"] = S.map({ job = job, plan = S.tok(24), page = S.int(0, 500), more = S.bool(),
    steps = S.array(S.map({ k = S.enum({ "take", "mine", "chop", "craft", "smelt", "machine", "supply" }),
      id = S.id(), n = count }, { x = coord, y = coord, z = coord }), 24) }),
  ["job.approve"] = S.map({ job = job, state = jobState }),
  ["lib.list"] = S.map({ items = S.array(S.map({ ref = ref, name = S.str(32), w = dim, h = dim, d = dim,
    count = count, tested = S.bool() }), 8), more = S.bool() }),
  ["lib.get_thumb"] = S.map({ ref = ref, w = S.int(1, 32), h = S.int(1, 32), data = S.bytes(1024) }),
  ["acct.get"] = S.map({ name = S.str(16), jobsActive = S.int(0, 100), jobsMax = S.int(0, 100),
    blocksMax = count, quotaUsed = S.int(0, 2 ^ 31), quotaMax = S.int(0, 2 ^ 31), devices = S.int(0, 100) }),
  ["upload.begin"] = S.map({ up = S.tok(24), next = S.int(0, 1024) }),
  ["upload.chunk"] = S.map({ up = S.tok(24), next = S.int(0, 1024) }),
  ["upload.end"] = S.map({ ref = ref }),
  ["import.link"] = S.map({ ref = ref }),
  ["import.status"] = S.map({ ref = ref, state = S.enum({ "queued", "fetching", "parsing", "ok", "rejected" }) },
    { code = S.enum({ "too_big", "bad_format", "bad_host", "timeout", "blocked_blocks", "quota" }),
      w = dim, h = dim, d = dim, count = count, dropped = count, hand = count }),
  ["rekey"] = S.map({}),
  ["w.claim"] = S.map({ job = job, stage = stage, limits = proto.TURTLE_LIMITS, scan = S.int(1, 24) }),
  ["w.survey"] = S.map({ next = S.int(0, 100001) }),
  ["w.inv"] = S.map({}),
  ["w.ops"] = S.map({ ops = S.array(opSpec, 32), done = S.bool(), limits = proto.TURTLE_LIMITS }),
  ["w.result"] = S.map({}),
  -- cells: each int packs (x*64 + z)*256 + (index into pal - 1), x and z relative to the layer origin
  ["w.layer"] = S.map({ y = S.int(0, 255), part = S.int(0, 255), more = S.bool(), pal = S.array(S.id(), 128),
    cells = S.array(S.int(0, 1048575), 1200) }),
  ["w.progress"] = S.map({ stop = S.bool() }),
  ["w.fault"] = S.map({ act = S.enum({ "wait", "retry", "abort" }) }),
  ["w.done"] = S.map({}),
}

proto.ERRORS = { "bad_request", "not_found", "not_allowed", "rate_limited", "quota", "busy", "maintenance",
  "too_big", "expired", "internal" }

local reqEnvelope = S.map({ v = S.int(1, 1), t = S.str(24), id = S.int(0, 2147483647), ts = S.int(0, 2 ^ 53) },
  { b = S.map({}) })
local resEnvelope = S.map({ v = S.int(1, 1), t = S.str(24), re = S.int(0, 2147483647), ok = S.bool() },
  { err = S.enum(proto.ERRORS) })

local function envelope(env, msg, bodies)
  if type(msg) ~= "table" then return nil, "message is not a table" end
  local body = msg.b
  msg.b = nil
  local ok, err = S.check(env, msg)
  msg.b = body
  if not ok then return nil, err end
  local spec = bodies[msg.t]
  if not spec then return nil, "t: unknown message type" end
  return spec, body
end

-- Check a request {v, t, id, ts, b}. Returns true, or nil plus a reason.
function proto.validate(msg)
  local spec, body = envelope(reqEnvelope, msg, proto.requests)
  if not spec then return nil, body end
  local ok, err = S.check(spec, body)
  if not ok then return nil, "b." .. err end
  if extra[msg.t] then
    err = extra[msg.t](body)
    if err then return nil, err end
  end
  return true
end

-- Check a response {v, t, re, ok, b} or {v, t, re, ok=false, err}.
function proto.validateResponse(msg)
  local spec, body = envelope(resEnvelope, msg, proto.responses)
  if not spec then return nil, body end
  if msg.ok then
    if msg.err then return nil, "err: not allowed when ok" end
    local ok, err = S.check(spec, body)
    if not ok then return nil, "b." .. err end
  elseif not msg.err or body ~= nil then
    return nil, "a failed response needs err and no body"
  end
  return true
end

return proto
]=]
F["lib/rpc.lua"] = [=[
-- Request/reply on top of the bus.
--
-- One coroutine must run R.pumpLoop(): it is the only place modem messages are decrypted, and it
-- turns them into local events. Any other coroutine can then use R.call(), and a server coroutine
-- runs R.serveLoop(handlers). In CC, start them with parallel.waitForAny.
--
--   local R = rpc.new{ bus = B, pull = os.pullEvent, startTimer = os.startTimer,
--                      queueEvent = os.queueEvent, clock = function() return os.epoch("utc") end }
local rpc = {}

local INBOX_MAX = 64

-- A handler returns this to send no reply at all (e.g. a standby server staying silent).
rpc.NOREPLY = {}

function rpc.new(opts)
  local B, pull, startTimer, queueEvent = opts.bus, opts.pull, opts.startTimer, opts.queueEvent
  local nextId = opts.clock() % 1000000 * 1000
  local inbox = {}
  local R = { bus = B }

  -- Feed one modem_message event in. Safe to call with any event.
  function R.pump(event, _, channel, _, payload)
    if event ~= "modem_message" then return end
    local got = B.receive(channel, payload)
    if not got then return end
    local msg = got.msg
    if msg.k == "r" and type(msg.id) == "number" then
      queueEvent("bus_reply", msg.id, got.src, msg)
    elseif (msg.k == "q" or msg.k == "n") and type(msg.m) == "string"
        and (msg.k == "n" or type(msg.id) == "number") then
      if #inbox < INBOX_MAX then
        inbox[#inbox + 1] = got
        queueEvent("bus_req")
      end
    end
  end

  function R.pumpLoop()
    while true do R.pump(pull("modem_message")) end
  end

  -- Returns the reply body, or nil plus an error code ("timeout", "no_key", or the server's code).
  function R.call(dst, method, body, timeoutSecs)
    nextId = nextId + 1
    local id = nextId
    local ok, err = B.send(dst, { k = "q", id = id, m = method, b = body or {} })
    if not ok then return nil, err end
    local timer = startTimer(timeoutSecs or 5)
    while true do
      local ev, a, b, c = pull()
      if ev == "bus_reply" and a == id and b == dst then
        if c.ok == 1 then return type(c.b) == "table" and c.b or {} end
        return nil, type(c.e) == "string" and c.e or "internal"
      elseif ev == "timer" and a == timer then
        return nil, "timeout"
      end
    end
  end

  -- Send without expecting a reply.
  function R.notify(dst, method, body)
    return B.send(dst, { k = "n", m = method, b = body or {} })
  end

  local function handle(handlers, got)
    local msg = got.msg
    local fn = handlers[msg.m]
    local ok, res, code
    if not fn then
      ok, res, code = true, nil, "no_method"
    else
      ok, res, code = pcall(fn, type(msg.b) == "table" and msg.b or {}, got.src, got.instance)
      if not ok then
        if opts.onError then pcall(opts.onError, msg.m, res) end
        res, code = nil, "internal"
      end
    end
    if msg.k ~= "q" or res == rpc.NOREPLY then return end
    if res ~= nil then
      local sent = B.send(got.src, { k = "r", id = msg.id, ok = 1, b = res })
      if not sent then B.send(got.src, { k = "r", id = msg.id, ok = 0, e = "too_big" }) end
    else
      B.send(got.src, { k = "r", id = msg.id, ok = 0, e = tostring(code or "internal") })
    end
  end

  -- Handle everything waiting in the inbox. handlers[method] = function(body, srcRole, srcInstance)
  -- returning a reply table, or nil plus an error code.
  function R.serveOnce(handlers)
    local n = 0
    while #inbox > 0 do
      handle(handlers, table.remove(inbox, 1))
      n = n + 1
    end
    return n
  end

  function R.serveLoop(handlers)
    while true do
      R.serveOnce(handlers)
      if #inbox == 0 then pull("bus_req") end
    end
  end

  return R
end

return rpc
]=]
F["lib/schema.lua"] = [=[
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
]=]
F["lib/sha256.lua"] = [=[
-- SHA-256 in pure Lua (uses bit32, available in CC: Tweaked and Lua 5.2).
-- Used to prove installed files and uploaded chunks were not altered.
local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift = bit32.rrotate, bit32.rshift
local byte = string.byte

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function block(h, s, at)
  local w = {}
  for i = 0, 15 do
    local a, b, c, d = byte(s, at + i * 4, at + i * 4 + 3)
    w[i + 1] = a * 16777216 + b * 65536 + c * 256 + d
  end
  for i = 17, 64 do
    local x, y = w[i - 15], w[i - 2]
    local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
    local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
  end
  local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  for i = 1, 64 do
    local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = (hh + S1 + ch + K[i] + w[i]) % 4294967296
    local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    local t2 = (S0 + maj) % 4294967296
    hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
  end
  h[1] = (h[1] + a) % 4294967296; h[2] = (h[2] + b) % 4294967296
  h[3] = (h[3] + c) % 4294967296; h[4] = (h[4] + d) % 4294967296
  h[5] = (h[5] + e) % 4294967296; h[6] = (h[6] + f) % 4294967296
  h[7] = (h[7] + g) % 4294967296; h[8] = (h[8] + hh) % 4294967296
end

local sha256 = {}
local Hasher = {}
Hasher.__index = Hasher

-- Streaming use: local h = sha256.new(); h:update(part); ...; local hex = h:finish()
function sha256.new()
  return setmetatable({
    h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
    buf = "", len = 0,
  }, Hasher)
end

function Hasher:update(s)
  self.len = self.len + #s
  local data = self.buf .. s
  local full = #data - #data % 64
  for at = 1, full, 64 do block(self.h, data, at) end
  self.buf = data:sub(full + 1)
  return self
end

function Hasher:finish()
  local bits = self.len * 8
  local pad = "\128" .. ("\0"):rep((55 - self.len) % 64)
  local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
  local function be(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
      math.floor(n / 256) % 256, n % 256)
  end
  local data = self.buf .. pad .. be(hi) .. be(lo)
  for at = 1, #data, 64 do block(self.h, data, at) end
  local out = {}
  for i = 1, 8 do out[i] = ("%08x"):format(self.h[i]) end
  return table.concat(out)
end

function sha256.hex(s)
  return sha256.new():update(s):finish()
end

return sha256
]=]
F["lib/storeclient.lua"] = [=[
-- Client for the storage service. Used by every base computer that needs to keep data.
--
--   local store = storeclient.new{ rpc = R, sleep = sleep }
--   store.put("jobs", "J1", "bytes")        store.get("jobs", "J1")
--   store.putTable("jobs", "J1", { ... })   store.getTable("jobs", "J1")
--   store.delete / store.list / store.stat / store.health
-- Every call returns its result, or nil plus an error code.
local codec = require("lib.codec")

local storeclient = {}

local PART = 32768
local RETRY = { timeout = true, busy = true }

function storeclient.new(opts)
  local R, sleep = opts.rpc, opts.sleep
  local retries = opts.retries or 3
  local timeout = opts.timeoutSecs or 15
  local nextUp = 0
  local C = {}

  -- one call with retries; a storage failover shows up as a few timeouts
  local function call(method, body)
    local res, err
    for attempt = 1, retries + 1 do
      res, err = R.call("storage", method, body, timeout)
      if res or not RETRY[err] then return res, err end
      if attempt <= retries and sleep then sleep(1) end
    end
    return nil, err
  end

  function C.put(ns, key, value)
    if type(value) ~= "string" then return nil, "bad_value" end
    if #value <= PART then
      local res, err = call("put", { ns = ns, key = key, d = value })
      if not res then return nil, err end
      return true
    end
    local n = math.ceil(#value / PART)
    for attempt = 1, retries + 1 do
      nextUp = nextUp + 1
      local up = "U" .. nextUp .. "x" .. (#value % 100000)
      local res, err
      for i = 1, n do
        res, err = call("put_part", { ns = ns, key = key, up = up, i = i, n = n,
          d = value:sub((i - 1) * PART + 1, i * PART) })
        if not res then break end
      end
      if res and res.done == 1 then return true end
      -- parts landed on a server that lost its memory (failover): start the upload again
      if res == nil and not RETRY[err] then return nil, err end
      if attempt > retries then return nil, err or "timeout" end
    end
  end

  function C.get(ns, key)
    for _ = 1, retries + 1 do
      local first, err = call("get_part", { ns = ns, key = key, i = 1 })
      if not first then return nil, err end
      local parts, changed = { first.d }, false
      for i = 2, first.n do
        local p, e = call("get_part", { ns = ns, key = key, i = i })
        if not p then
          if e ~= "bad_request" and e ~= "not_found" then return nil, e end
          changed = true
          break
        end
        if p.ver ~= first.ver then changed = true; break end
        parts[i] = p.d
      end
      if not changed then return table.concat(parts) end
      -- the value was replaced while we were reading it: read again
    end
    return nil, "busy"
  end

  function C.delete(ns, key)
    local res, err = call("delete", { ns = ns, key = key })
    if not res then return nil, err end
    return true
  end

  -- Returns keys, more (or nil, err).
  function C.list(ns, prefix, after, limit)
    local res, err = call("list", { ns = ns, prefix = prefix, after = after, limit = limit })
    if not res then return nil, err end
    return res.keys, res.more == 1
  end

  function C.stat(ns, key) return call("stat", { ns = ns, key = key }) end
  function C.health() return call("health", {}) end

  function C.putTable(ns, key, tbl)
    local ok, data = pcall(codec.encode, tbl)
    if not ok then return nil, "bad_value" end
    return C.put(ns, key, data)
  end

  function C.getTable(ns, key)
    local data, err = C.get(ns, key)
    if not data then return nil, err end
    local tbl = codec.decode(data, { maxItems = 200000, maxDepth = 16 })
    if type(tbl) ~= "table" then return nil, "corrupt" end
    return tbl
  end

  return C
end

return storeclient
]=]
F["manifest.lua"] = [=[
return { version = "0.2.5", roles = {
  ["compute"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/compute/config.lua", dest = "/bs/role/config.lua", size = 1968, sha256 = "7999f0f41ddb2cfaf381c27d8b985cbd7a3a2a41c6c390137bcd9fa1a578140d" },
  },
  ["gps"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/gps/config.lua", dest = "/bs/role/config.lua", size = 190, sha256 = "85fe938cc195c3ac940ee8393d3a33930defb6617a2746ba43d329b1d690ee7d" },
  },
  ["incoming"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/incoming/config.lua", dest = "/bs/role/config.lua", size = 578, sha256 = "edb4587aaff94d49a0072144ed952af1dd7f62723bae36970d301245bea79c39" },
  },
  ["ingest"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/ingest/config.lua", dest = "/bs/role/config.lua", size = 700, sha256 = "872f5441de65c61a8b2d00ec82296cd1edd87253498f01fed3a8d7c551679c56" },
  },
  ["monitor"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/monitor/config.lua", dest = "/bs/role/config.lua", size = 584, sha256 = "26c33f40d33b1684bc252e7275f1b73c2b38bc8374739a7ab711d918c52fca26" },
  },
  ["outgoing"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/outgoing/config.lua", dest = "/bs/role/config.lua", size = 419, sha256 = "d0497198d4e53c00b033e95b0efdd0f4e2019464b5bbbc7a8e95404d2f9f3f9e" },
  },
  ["pocket"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/pocket/config.lua", dest = "/bs/role/config.lua", size = 416, sha256 = "baa68559d18844060ebc4c59e4e1e0276cf621725a52546cc79a2182d9b37cda" },
  },
  ["register"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/register/config.lua", dest = "/bs/role/config.lua", size = 476, sha256 = "f5766e0dd31f2aed84c321984273b8439ad2ef3e075106edb753b7521c9f9ab3" },
  },
  ["storage"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/storage/config.lua", dest = "/bs/role/config.lua", size = 935, sha256 = "bab754bf5e3aa317b13944f200bad4afdd505464b8f961a90026730fa5d9fa0d" },
    { path = "roles/storage/device.lua", dest = "/bs/roles/storage/device.lua", size = 3305, sha256 = "65148aa98ef1926a7475a7e0fe9073fc42038677854a3a4c064b7abae8bd99eb" },
    { path = "roles/storage/engine.lua", dest = "/bs/roles/storage/engine.lua", size = 26548, sha256 = "fca5a92737f30e75696ac888fb5fb3557de777b4d785d7e4c1aff5b13549b788" },
    { path = "roles/storage/main.lua", dest = "/bs/role/main.lua", size = 3187, sha256 = "37471e9f68f5bc0365e77b5d280c063419e21dfd4805da152f70ef7ccd00c9a3" },
    { path = "roles/storage/server.lua", dest = "/bs/roles/storage/server.lua", size = 7509, sha256 = "42d7079f4d5160ce38ea0e8012f343b4ab18b6c49655914c23516b1de5391813" },
  },
  ["worker"] = {
    { path = "lib/base64.lua", dest = "/bs/lib/base64.lua", size = 1927, sha256 = "62fb218cdb68e781588899dae88cda0905243e283c132a23484453d2364eb075" },
    { path = "lib/bus.lua", dest = "/bs/lib/bus.lua", size = 3156, sha256 = "7a92c5f087041d3efadf5982b402615c1e206b7045e7d0878393b33c58cb275d" },
    { path = "lib/codec.lua", dest = "/bs/lib/codec.lua", size = 5005, sha256 = "afa624bd1a489550c05ff69434777ca2e875d0700ed8833e2d6d03dd1ef3512c" },
    { path = "lib/config.lua", dest = "/bs/lib/config.lua", size = 2911, sha256 = "34732f03864dc735cc444ba2b3bdbadf7835aa6e40cf1f4b4a5bae91f1166e59" },
    { path = "lib/config_specs.lua", dest = "/bs/lib/config_specs.lua", size = 2901, sha256 = "600eb2a0057d3be275b2a25ec36c0166d4dedeeadbb01286fda8f010a2633a6b" },
    { path = "lib/crypto.lua", dest = "/bs/lib/crypto.lua", size = 2491, sha256 = "0eabb85d13eb7cdcd1e60b47c3401a75f2bd3aa03ad9f876c73c3a5f1e147486" },
    { path = "lib/log.lua", dest = "/bs/lib/log.lua", size = 2154, sha256 = "2b6ae0ade22913051f03e5e6f5a2c446cf0f4c3a2b465f07d727247784d73cfe" },
    { path = "lib/proto.lua", dest = "/bs/lib/proto.lua", size = 10902, sha256 = "24b68df1976c8dc559d5786ea579d4f8bfd47b3be7bbec016bd99929a198ba83" },
    { path = "lib/rpc.lua", dest = "/bs/lib/rpc.lua", size = 3691, sha256 = "458db6de7c8c9b1e68f2987df707fe35659b9b8be5fa31b1b869515ea8a55d0f" },
    { path = "lib/schema.lua", dest = "/bs/lib/schema.lua", size = 5776, sha256 = "245e926f2c323edfc1292afdd02caa5a1d925b91e5288f1931ea833be15e7ba0" },
    { path = "lib/sha256.lua", dest = "/bs/lib/sha256.lua", size = 3512, sha256 = "2958e0101a3cd28662a7b07e208afdd09cde9078282e4b4f65d842e6ee89fdbc" },
    { path = "lib/storeclient.lua", dest = "/bs/lib/storeclient.lua", size = 3759, sha256 = "f2741475f2088692eddb50a8340d837429f7b6914b0e128f15b305ae445174e3" },
    { path = "install/install.lua", dest = "/bs/install/install.lua", size = 2993, sha256 = "eeeb97fc63687423d71fb3e566048b8c02e386884574baa787dfed6fdfa4966b" },
    { path = "install/installer_core.lua", dest = "/bs/install/installer_core.lua", size = 4475, sha256 = "3506c96d1f3733ee1f466ccd144f56554f2783bfae7fccd6e2e15ef455b23994" },
    { path = "install/keys_core.lua", dest = "/bs/install/keys_core.lua", size = 2168, sha256 = "89cc5a6bab2ee9ac34c63a7b60a6c9181a8d61abe8ea48ba98f011505f160d52" },
    { path = "install/mkkeys.lua", dest = "/bs/install/mkkeys.lua", size = 2232, sha256 = "f8bb38452d641603fb969876ae7b6c5dcb68a022d31cd3b4edcab1306efbe2f3" },
    { path = "install/setup.lua", dest = "/bs/install/setup.lua", size = 8236, sha256 = "346a5c59bee23e276c48071ae5fef8aeeb167f058435f1a7beae589bca439972" },
    { path = "install/setup_ui.lua", dest = "/bs/install/setup_ui.lua", size = 3091, sha256 = "32317821e4ac9f473826571b1c5de7a63ff963c67027f8f12349fd311b5262b2" },
    { path = "install/storetest.lua", dest = "/bs/install/storetest.lua", size = 3497, sha256 = "c84567e3f6b093e68d0a93862279fbfe3e45c1f19efda8c2a0d40f3af5c8e198" },
    { path = "install/verify.lua", dest = "/bs/install/verify.lua", size = 2216, sha256 = "2533b7c381976974b0467ba2e2d16acccff5603b6d3fdea39d8ee6b65375ddbd" },
    { path = "install/verify_core.lua", dest = "/bs/install/verify_core.lua", size = 10715, sha256 = "4ffda52ad53368d0b71c912a6b13c890c30906e2e42e618e51e0fa806bd2bd55" },
    { path = "roles/_common/startup.lua", dest = "/startup.lua", size = 1736, sha256 = "838b2f8848d67fec32b0c56f74d2a768d4179c59e05ab1e30d2a3f9b3a5c673f" },
    { path = "roles/_common/setup.lua", dest = "/setup.lua", size = 110, sha256 = "dd3ee91605b7db2a7c4754a0df31923209807e73d7cbee5db5d4717241645888" },
    { path = "vendor/ccryptolib/aead.lua", dest = "/bs/ccryptolib/aead.lua", size = 3866, sha256 = "738c69c55a2894ffde108267dbdc4ae2d953d6b3122dbc03002389fe65fb67a0" },
    { path = "vendor/ccryptolib/blake3.lua", dest = "/bs/ccryptolib/blake3.lua", size = 8917, sha256 = "a495f9ab1c7ffaeeb6a273788adce9ba2fbe2012a5ba46bd8bce0624698982d1" },
    { path = "vendor/ccryptolib/chacha20.lua", dest = "/bs/ccryptolib/chacha20.lua", size = 5149, sha256 = "a741161fba6bcf04556554aa42b7b304e4b639f01b53601d462907df39cd6dac" },
    { path = "vendor/ccryptolib/config.lua", dest = "/bs/ccryptolib/config.lua", size = 919, sha256 = "bc95f607825536e21f6bc8d936990cbd1c997fe6641ee031aaef972a11371287" },
    { path = "vendor/ccryptolib/ed25519.lua", dest = "/bs/ccryptolib/ed25519.lua", size = 3300, sha256 = "15af5a1773347460c59a47d2635e1d6e67ae7f9940b896b8f7740b1f378ea5e0" },
    { path = "vendor/ccryptolib/internal/curve25519.lua", dest = "/bs/ccryptolib/internal/curve25519.lua", size = 9789, sha256 = "8730d8f2b7970c835e3a2a42816a8879fee1cc318dca85bacaca0b7b873e8cab" },
    { path = "vendor/ccryptolib/internal/edwards25519.lua", dest = "/bs/ccryptolib/internal/edwards25519.lua", size = 8845, sha256 = "c943e22757dcf339b847d699bb90662cec5f50c624921aef9fb7ffbbc66f59d8" },
    { path = "vendor/ccryptolib/internal/fp.lua", dest = "/bs/ccryptolib/internal/fp.lua", size = 20753, sha256 = "543ac4a1f9cb374a707ed63f94ff32b0341e495ccbb8c6ef5d8a936039cd7c08" },
    { path = "vendor/ccryptolib/internal/fq.lua", dest = "/bs/ccryptolib/internal/fq.lua", size = 11778, sha256 = "4161d0fe692ed3c8a82a4d72cce4e9ead7b7405a09c0b51d02d87c6054d7113b" },
    { path = "vendor/ccryptolib/internal/hw.lua", dest = "/bs/ccryptolib/internal/hw.lua", size = 3145, sha256 = "c1420f387520ce054e0fb2e41c45e246daebda3d38c23a75a71fbfdec666b246" },
    { path = "vendor/ccryptolib/internal/mp.lua", dest = "/bs/ccryptolib/internal/mp.lua", size = 10367, sha256 = "d6b955cdc6edbc7dcce667b612492f4e3620fee424ce4b8681fa3daa997a1074" },
    { path = "vendor/ccryptolib/internal/packing.lua", dest = "/bs/ccryptolib/internal/packing.lua", size = 5343, sha256 = "12ceb7323c616289071a3d5e255cf0dade7a7532580155f91b7ac3047bb59476" },
    { path = "vendor/ccryptolib/internal/sha512.lua", dest = "/bs/ccryptolib/internal/sha512.lua", size = 6948, sha256 = "989affb1c13828a299195574faa56f3a5d6498c65c739ead7da5d8c50e4e7e37" },
    { path = "vendor/ccryptolib/internal/util.lua", dest = "/bs/ccryptolib/internal/util.lua", size = 1843, sha256 = "711be5e43900fc3af46c61e812bd64c48abcc6b78d698eb9fb82f0285eef6844" },
    { path = "vendor/ccryptolib/poly1305.lua", dest = "/bs/ccryptolib/poly1305.lua", size = 4574, sha256 = "7184ab3a15c855034d1472e57b6432561e86b33b6c7eaba14863a870219c8a69" },
    { path = "vendor/ccryptolib/random.lua", dest = "/bs/ccryptolib/random.lua", size = 4041, sha256 = "bd55dc49f579bf808ea3cca624218e8651fa1da658ba8242a2bd948212f59f48" },
    { path = "vendor/ccryptolib/sha256.lua", dest = "/bs/ccryptolib/sha256.lua", size = 4652, sha256 = "956557af41b419e18c5214d9ed337fb905531e23de4b7f53bfa6a8699f52c64e" },
    { path = "vendor/ccryptolib/util.lua", dest = "/bs/ccryptolib/util.lua", size = 1312, sha256 = "cdce1c0e75a4e56097853e4aa85fb76366866078e4694db00ebc958785c96caf" },
    { path = "vendor/ccryptolib/x25519.lua", dest = "/bs/ccryptolib/x25519.lua", size = 1350, sha256 = "f8618a0641c48721f21ea1dfc63a06eafb75efc4be6fbcc6a2939dc80a55c72b" },
    { path = "vendor/ccryptolib/x25519c.lua", dest = "/bs/ccryptolib/x25519c.lua", size = 6568, sha256 = "1dcf554322d946a426bc04cfb4936ab740aa75078fa7209b6ac1b032d4fbe222" },
    { path = "roles/worker/config.lua", dest = "/bs/role/config.lua", size = 436, sha256 = "1f37796015db0ede2ae5c0384d2a182e68fecb8ec7f5a45a4e9f983d0809fab2" },
  },
} }
]=]
F["roles/_common/setup.lua"] = [=[
-- Shortcut: type `setup` anywhere to open the BuildKit setup screen.
shell.run("/bs/install/setup.lua", ...)
]=]
F["roles/_common/startup.lua"] = [=[
-- Boot file for every BuildKit computer. Runs the role program and restarts it if it crashes.
-- After 5 crashes within 2 minutes it stops, so a broken program cannot reboot-loop forever.
package.path = "/bs/?.lua;/bs/?/init.lua;" .. package.path

local MAIN, CRASH_LOG, CRASHES = "/bs/role/main.lua", "/bs/crash.log", "/bs/.crashes"

local function readAll(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local function writeAll(path, s)
  local h = fs.open(path, "w")
  if h then h.write(s); h.close() end
end

if fs.exists("/bs/.installing") then
  printError("An install did not finish. Run the install program again.")
  return
end

local fn, loadErr = loadfile(MAIN, nil, _ENV)
if not fn then
  printError("Cannot start " .. MAIN .. ": " .. tostring(loadErr))
  printError("Run the install program to set this computer up.")
  return
end

local ok, err = pcall(fn)
if ok then return end

-- crashed: log it (keeping the log small), then reboot unless it keeps happening
local now = os.epoch("utc")
local log = (readAll(CRASH_LOG) or "") .. ("[%d] %s\n"):format(now, tostring(err):sub(1, 2000))
if #log > 12000 then log = log:sub(-8000) end
pcall(writeAll, CRASH_LOG, log)

local count, first = (readAll(CRASHES) or ""):match("^(%d+) (%d+)")
count, first = tonumber(count) or 0, tonumber(first) or now
if now - first > 120000 then count, first = 0, now end
count = count + 1
pcall(writeAll, CRASHES, count .. " " .. first)

printError("Program crashed: " .. tostring(err):sub(1, 200))
if count > 5 then
  printError("Crashed " .. count .. " times in a row. Stopped. See " .. CRASH_LOG)
  return
end
print("Restarting in 10 seconds...")
sleep(10)
os.reboot()
]=]
F["roles/compute/config.lua"] = [=[
-- COMPUTE config: limits, quotas and the maximums players can choose for their turtle.
return {
  limits = {
    jobsActive = 3,           -- jobs one player may have running at once
    jobBlocks = 20000,        -- biggest build, in blocks
    uploadBytes = 262144,     -- biggest uploaded schematic file
    schematicQuota = 2097152, -- stored schematic bytes per player
  },
  -- The most a player may allow their turtle. Players can only choose equal or lower on the pocket.
  turtleMax = {
    w = 48, d = 48, up = 64, down = 64, -- work area size
    take = "all",        -- "none", "marked" (only containers with the marker block on top) or "all"
    mine = true, mineMax = 4096,
    chop = true,
    machines = true,
    me = false,          -- attaching to ME networks is off until tested
    fuelReserve = 20000,
    maxMinutes = 1440,
    keepOut = {},
  },
  -- Block that marks a container as "the turtle may take from this" in "marked" mode (placed on top).
  marker = "minecraft:lime_wool",
  -- World areas no turtle may work in: { x1, y1, z1, x2, y2, z2 } in world coordinates.
  noBuild = {},
  -- Players who get a bigger share of the queue: { player = "Name", weight = 1..10 }.
  priorities = {},
  -- Blocks a turtle may dig out of its way. Everything else it goes around.
  replaceable = {
    "minecraft:short_grass", "minecraft:tall_grass", "minecraft:fern", "minecraft:large_fern",
    "minecraft:snow", "minecraft:water", "minecraft:lava", "minecraft:dead_bush", "minecraft:vine",
    "minecraft:dandelion", "minecraft:poppy",
  },
  -- Let turtles try to build their own small Create machines (experimental).
  level4 = false,
  -- How long (minutes) a quote stays valid.
  quoteMinutes = 15,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/gps/config.lua"] = [=[
-- GPS host config. Stand where the computer is, press F3, and copy the block coordinates here.
return {
  set = false, -- change to true once x, y, z are filled in
  x = 0, y = 0, z = 0,
}
]=]
F["roles/incoming/config.lua"] = [=[
-- INCOMING gateway config.
return {
  frameMax = 8192,     -- biggest message accepted, in bytes
  clockSkewSecs = 120, -- how far a message's timestamp may be from server time
  rate = { burst = 5, perMinute = 60 },         -- per pocket
  workerRate = { burst = 20, perMinute = 600 }, -- per turtle (surveys send many messages)
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/ingest/config.lua"] = [=[
-- INGEST computer config: the only computer allowed to download schematics.
return {
  -- Exact host names downloads are allowed from. Nothing else is fetched.
  allowHosts = { "cdn.modrinth.com", "raw.githubusercontent.com" },
  maxBytes = 262144,     -- biggest download
  maxInflated = 4194304, -- biggest size after unpacking (stops "zip bombs")
  maxDim = 64,           -- biggest schematic side, in blocks
  timeoutSecs = 20,
  maxRedirects = 2,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/monitor/config.lua"] = [=[
-- MONITOR room config.
return {
  pinRequired = true, -- ask for the admin PIN before dangerous actions
  alarmSide = "none", -- redstone side to power on an alarm: "none", "top", "bottom", "left", "right", "front", "back"
  speaker = true,     -- play alarm sounds if a speaker is attached
  refreshMs = 500,    -- screen refresh time
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/outgoing/config.lua"] = [=[
-- OUTGOING gateway config.
return {
  frameMax = 8192, -- biggest message sent, in bytes
  queueMax = 256,  -- most replies waiting to be sent before new ones are dropped
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/pocket/config.lua"] = [=[
-- POCKET app config.
return {
  theme = "dark",    -- "dark" or "light"
  renderer = "auto", -- "auto", "gfx" (CC: Graphics), "teletext" or "text"
  animations = true,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/register/config.lua"] = [=[
-- REGISTER terminal config.
return {
  -- Your Minecraft name. Only this player can enrol pockets and turtles. CHANGE THIS.
  owner = "CHANGE_ME",
  -- How close (blocks) a player must stand to be registered.
  detectRange = 3,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/storage/config.lua"] = [=[
-- STORAGE manager config. Edit values, keep the shape. Bad values stop the program with a clear message.
return {
  -- Which storage manager this is (1, 2, ...). Each one needs a different number.
  id = 1,
  -- How many NBT Storage blocks each piece of data is copied to.
  replicas = 2,
  -- Size of one piece of data. Minecraft cannot store a single text over 65535 bytes in a block,
  -- so anything above 45000 here is treated as 45000.
  shardBytes = 40000,
  -- Size limit of one NBT Storage block (nbtStorageMaxSize in the Advanced Peripherals config, minus headroom).
  deviceMaxBytes = 1000000,
  -- How often (minutes) to re-check stored data for damage.
  scrubMinutes = 30,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["roles/storage/device.lua"] = [=[
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
]=]
F["roles/storage/engine.lua"] = [=[
-- Storage engine: a replicated key/value store spread over many NBT Storage blocks ("devices").
--
-- How it stays safe:
--  * A value is cut into shards. Each shard is written as a "cell" to `replicas` different devices.
--  * Every cell describes itself (key, version, part number, hash). The index in memory can
--    therefore always be rebuilt by scanning the devices; nothing else needs to survive a crash.
--  * A new version is written completely, and read back, before the old one is removed. After a
--    power cut, rebuild() keeps the highest version that is complete and removes the rest.
--  * Deleting first writes a small "tombstone" cell with a higher version, so a half-finished
--    delete can never bring the old value back.
--
-- The engine is not re-entrant: run all operations from one coroutine.
local base64 = require("lib.base64")

local engine = {}

local NAMESPACES = { players = true, jobs = true, schematics = true, recipes = true, library = true,
  surveys = true, logs = true, config = true }
local MAX_VALUE = 4194304
-- One shard becomes one NBT string (base64, so 4/3 larger, plus a short header). Minecraft's limit
-- for a single NBT string is 65535 bytes, so a shard may hold at most 45000 raw bytes (60000 encoded).
local MAX_SHARD = 45000

-- Cell text: "<ns/key>|<ver>|<i>|<n>|<size>|<hash>|<flag>\n<base64 data>"
local function makeCell(k, ver, i, n, size, hash, flag, data)
  return ("%s|%d|%d|%d|%d|%s|%s\n%s"):format(k, ver, i, n, size, hash, flag, data)
end

local function parseHeader(cell)
  local nl = cell:find("\n", 1, true)
  if not nl then return nil end
  local k, ver, i, n, size, hash, flag = cell:sub(1, nl - 1):match(
    "^([a-z]+/[A-Za-z0-9_.:-]+)|(%d+)|(%d+)|(%d+)|(%d+)|([0-9a-f-]+)|([dx])$")
  if not k then return nil end
  return { k = k, ver = tonumber(ver), i = tonumber(i), n = tonumber(n), size = tonumber(size),
    hash = hash, flag = flag }, nl
end

function engine.new(opts)
  local crypto = opts.crypto
  local replicas = opts.replicas or 2
  local shardBytes = math.min(opts.shardBytes or 40000, MAX_SHARD)
  local deviceMax = opts.deviceMaxBytes or 1000000
  local yield = opts.yield or function() end

  local devices = {}  -- name -> D
  local order = {}    -- device names, sorted
  local dir = {}      -- name -> { [cellId] = meta } (meta has .bytes)
  local used = {}     -- name -> bytes in use
  local devOk = {}    -- name -> false when the last load failed
  local byKey = {}    -- k -> { [name .. "/" .. cellId] = { dev = name, id = cellId, meta = meta } }
  local index = {}    -- k -> { ver, n, size, shards = { [i] = { hash, devs = { name... } } } }
  local lost = {}      -- k -> true when every copy of some shard is gone
  local degraded = {}  -- k -> true when a key may have fewer copies than wanted
  local locked = false
  local fromSnapshot = false
  local scrubPos = 0
  local hot, cacheMax = opts.hot or {}, opts.cacheBytes or 262144
  local cache, cacheUse, cacheBytes, cacheTick = {}, {}, 0, 0

  local function cacheDrop(k)
    if cache[k] then cacheBytes = cacheBytes - #cache[k]; cache[k], cacheUse[k] = nil, nil end
  end

  local function cachePut(k, value)
    cacheDrop(k)
    if not hot[k:match("^[a-z]+")] or #value > cacheMax then return end
    cacheTick = cacheTick + 1
    cache[k], cacheUse[k], cacheBytes = value, cacheTick, cacheBytes + #value
    while cacheBytes > cacheMax do
      local oldest
      for key, tick in pairs(cacheUse) do
        if not oldest or tick < cacheUse[oldest] then oldest = key end
      end
      cacheDrop(oldest)
    end
  end

  local E = {}

  local function addDevice(D)
    devices[D.name] = D
    order[#order + 1] = D.name
    table.sort(order)
    dir[D.name], used[D.name], devOk[D.name] = {}, 0, true
  end
  for _, D in ipairs(opts.devices or {}) do addDevice(D) end

  local function cellId(k, ver, i)
    return "c" .. crypto.hashHex(k .. "|" .. ver .. "|" .. i):sub(1, 16)
  end

  local function checkName(ns, key)
    if type(ns) ~= "string" or not NAMESPACES[ns] then return nil end
    if type(key) ~= "string" or #key < 1 or #key > 96 or key:find("[^A-Za-z0-9_.:-]") then return nil end
    return ns .. "/" .. key
  end

  -- Replace what we know about one device with what was just read from / written to it.
  -- Returns the ids of entries that are not valid cells.
  local function refresh(name, cells)
    for id in pairs(dir[name]) do
      local set = byKey[dir[name][id].k]
      if set then
        set[name .. "/" .. id] = nil
        if next(set) == nil then byKey[dir[name][id].k] = nil end
      end
    end
    local metas, total, junk = {}, 0, {}
    for id, cell in pairs(cells) do
      local meta = parseHeader(cell)
      if meta and id == cellId(meta.k, meta.ver, meta.i) then
        meta.bytes = #id + #cell
        metas[id] = meta
        total = total + meta.bytes
        byKey[meta.k] = byKey[meta.k] or {}
        byKey[meta.k][name .. "/" .. id] = { dev = name, id = id, meta = meta }
      else
        junk[#junk + 1] = id
        total = total + #id + #cell
      end
    end
    dir[name], used[name], devOk[name] = metas, total, true
    return junk
  end

  -- Read a device, change it, write it back. add: { id = cell }, remove: list of ids.
  -- With verify, the device is read again and the added cells compared.
  local function mutate(name, add, remove, verify)
    local D = devices[name]
    local cells = D.load()
    yield()
    if not cells then devOk[name] = false; return nil, "io" end
    for _, id in ipairs(remove or {}) do cells[id] = nil end
    for id, cell in pairs(add or {}) do cells[id] = cell end
    local ok = D.store(cells)
    yield()
    if not ok then return nil, "io" end
    if verify then
      local back = D.load()
      yield()
      if not back then devOk[name] = false; return nil, "io" end
      for id, cell in pairs(add) do
        if back[id] ~= cell then refresh(name, back); return nil, "io" end
      end
      cells = back
    end
    refresh(name, cells)
    return true
  end

  -- Work out the current state of one key from the cells that exist.
  -- Returns: entry (nil if deleted/absent), stale cell refs, tombstone cell refs, highest version seen.
  local function resolve(k)
    local set = byKey[k]
    if not set then return nil, {}, {}, 0 end
    local versions, maxVer = {}, 0
    for _, ref in pairs(set) do
      local m = ref.meta
      local v = versions[m.ver]
      if not v then
        v = { ver = m.ver, flag = m.flag, n = m.n, size = m.size, shards = {}, refs = {} }
        versions[m.ver] = v
      end
      v.refs[#v.refs + 1] = ref
      if m.flag == "d" and v.flag == "d" and m.n == v.n and m.i >= 1 and m.i <= m.n then
        local sh = v.shards[m.i]
        if not sh then sh = { hash = m.hash, devs = {} }; v.shards[m.i] = sh end
        if sh.hash == m.hash then sh.devs[#sh.devs + 1] = ref.dev end
      end
      if m.ver > maxVer then maxVer = m.ver end
    end
    local winner
    for ver, v in pairs(versions) do
      local complete = v.flag == "x"
      if not complete then
        complete = v.n >= 1
        for i = 1, v.n do
          if not v.shards[i] then complete = false; break end
        end
      end
      if complete and (not winner or ver > winner.ver) then winner = v end
    end
    local stale, tombs = {}, {}
    for _, v in pairs(versions) do
      for _, ref in ipairs(v.refs) do
        if v ~= winner then
          stale[#stale + 1] = ref
        elseif v.flag == "x" then
          tombs[#tombs + 1] = ref
        end
      end
    end
    if not winner or winner.flag == "x" then return nil, stale, tombs, maxVer end
    for _, sh in pairs(winner.shards) do table.sort(sh.devs) end
    return { ver = winner.ver, n = winner.n, size = winner.size, shards = winner.shards }, stale, tombs, maxVer
  end

  -- Remove a list of cell refs, one device write per device. Returns true if all were removed.
  local function removeRefs(refs)
    local per = {}
    for _, ref in ipairs(refs) do
      per[ref.dev] = per[ref.dev] or {}
      per[ref.dev][#per[ref.dev] + 1] = ref.id
    end
    local all = true
    for _, name in ipairs(order) do
      if per[name] and not mutate(name, nil, per[name]) then all = false end
    end
    return all
  end

  local function allDevicesReadable()
    for _, name in ipairs(order) do
      if not devOk[name] then return false end
    end
    return true
  end

  -- Bring one key to its clean state: drop stale cells, finish deletes.
  local function settle(k)
    local entry, stale, tombs = resolve(k)
    local clean = removeRefs(stale)
    if not entry and #tombs > 0 and clean and allDevicesReadable() then removeRefs(tombs) end
    index[k] = entry
    cacheDrop(k)
    lost[k] = nil
    return entry
  end

  local function readyCount()
    local n = 0
    for _, name in ipairs(order) do
      if devOk[name] then n = n + 1 end
    end
    return n
  end

  local function underReplicated(entry)
    local want = math.min(replicas, readyCount())
    for i = 1, entry.n do
      if #entry.shards[i].devs < want then return true end
    end
    return false
  end

  -- Choose devices for a set of cells. sizes[i] = bytes of cell i. Returns { [i] = { name... } } or nil.
  local function place(sizes, want)
    local free = {}
    for _, name in ipairs(order) do
      if devOk[name] then free[name] = deviceMax - used[name] end
    end
    local plan = {}
    for i, bytes in ipairs(sizes) do
      local picked = {}
      for _ = 1, want do
        local best
        for _, name in ipairs(order) do
          if free[name] and free[name] >= bytes and not picked[name]
              and (not best or free[name] > free[best]) then
            best = name
          end
        end
        if not best then return nil end
        picked[best] = true
        picked[#picked + 1] = best
        free[best] = free[best] - bytes
      end
      plan[i] = picked
    end
    return plan
  end

  -- Write a set of new cells: cells[i] = { id, text }. Returns true or nil, err; on error nothing new remains.
  local function writeCells(cells)
    local want = math.min(replicas, readyCount())
    if want < 1 then return nil, "no_space" end
    local sizes = {}
    for i, c in ipairs(cells) do sizes[i] = #c.id + #c.text end
    local plan = place(sizes, want)
    if not plan then return nil, "no_space" end
    local per = {}
    for i, names in ipairs(plan) do
      for _, name in ipairs(names) do
        per[name] = per[name] or {}
        per[name][cells[i].id] = cells[i].text
      end
    end
    local done = {}
    for _, name in ipairs(order) do
      if per[name] then
        done[#done + 1] = name
        if not mutate(name, per[name], nil, true) then
          -- undo: remove whatever of the new version got written
          for _, written in ipairs(done) do
            local ids = {}
            for id in pairs(per[written]) do ids[#ids + 1] = id end
            mutate(written, nil, ids)
          end
          return nil, "io"
        end
      end
    end
    return true
  end

  local function guarded(fn)
    return function(...)
      if locked then return nil, "busy" end
      locked = true
      local res = { pcall(fn, ...) }
      locked = false
      if not res[1] then error(res[2], 0) end
      return table.unpack(res, 2)
    end
  end

  -- Scan every device and rebuild the index. Run at boot and after taking over as primary.
  local function rebuildInner()
    fromSnapshot = false
    lost, degraded, cache, cacheUse, cacheBytes = {}, {}, {}, {}, 0
    local report = { devices = #order, unreadable = 0, cells = 0, keys = 0, removed = 0 }
    byKey, index = {}, {}
    for _, name in ipairs(order) do dir[name] = {} end
    for _, name in ipairs(order) do
      local cells = devices[name].load()
      yield()
      if not cells then
        devOk[name] = false
        report.unreadable = report.unreadable + 1
      else
        local junk = refresh(name, cells)
        if #junk > 0 and mutate(name, nil, junk) then report.removed = report.removed + #junk end
      end
    end
    local keys = {}
    for k in pairs(byKey) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local _, stale = resolve(k)
      report.removed = report.removed + #stale
      local entry = settle(k)
      if entry then
        report.keys = report.keys + 1
        if underReplicated(entry) then degraded[k] = true end
      end
    end
    for _, name in ipairs(order) do
      for _ in pairs(dir[name]) do report.cells = report.cells + 1 end
    end
    return report
  end
  E.rebuild = guarded(rebuildInner)

  E.put = guarded(function(ns, key, value)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    if type(value) ~= "string" then return nil, "bad_value" end
    if #value > MAX_VALUE then return nil, "too_big" end
    local _, _, _, maxVer = resolve(k)
    local ver = maxVer + 1
    local n = math.max(1, math.ceil(#value / shardBytes))
    local cells = {}
    for i = 1, n do
      local part = value:sub((i - 1) * shardBytes + 1, i * shardBytes)
      cells[i] = { id = cellId(k, ver, i),
        text = makeCell(k, ver, i, n, #value, crypto.hashHex(part), "d", base64.encode(part)) }
      yield()
    end
    local ok, err = writeCells(cells)
    if not ok then return nil, err end
    settle(k) -- the new version is complete now; this removes the old one
    return true
  end)

  local function getInner(k)
    local entry = index[k]
    if not entry then return nil, "not_found" end
    if cache[k] then
      cacheTick = cacheTick + 1
      cacheUse[k] = cacheTick
      return cache[k]
    end
    local parts, loaded = {}, {}
    for i = 1, entry.n do
      local sh, id = entry.shards[i], cellId(k, entry.ver, i)
      for _, name in ipairs(sh.devs) do
        if loaded[name] == nil then
          loaded[name] = devices[name] and devices[name].load() or false
          yield()
        end
        local cell = loaded[name] and loaded[name][id]
        if cell then
          local meta, nl = parseHeader(cell)
          local data = meta and base64.decode(cell:sub(nl + 1))
          if data and crypto.hashHex(data) == sh.hash then parts[i] = data; break end
        end
        degraded[k] = true -- this copy was missing or damaged; scrub will repair it
      end
      if not parts[i] then return nil, "corrupt" end
    end
    local value = table.concat(parts)
    cachePut(k, value)
    return value
  end

  E.get = guarded(function(ns, key)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    local value, err = getInner(k)
    if value == nil and fromSnapshot then
      -- the boot snapshot may be out of date: scan for real, then try once more
      rebuildInner()
      value, err = getInner(k)
    end
    return value, err
  end)

  E.delete = guarded(function(ns, key)
    local k = checkName(ns, key)
    if not k then return nil, "bad_key" end
    if not index[k] then return nil, "not_found" end
    local _, _, _, maxVer = resolve(k)
    local ver = maxVer + 1
    local ok, err = writeCells({ { id = cellId(k, ver, 0), text = makeCell(k, ver, 0, 0, 0, "-", "x", "") } })
    if not ok then return nil, err end
    settle(k) -- the tombstone wins now; this removes the data, then the tombstone
    return true
  end)

  -- Keys in a namespace, sorted. Returns keys, more.
  function E.list(ns, prefix, after, limit)
    if type(ns) ~= "string" or not NAMESPACES[ns] then return {}, false end
    local want = ns .. "/" .. (prefix or "")
    local keys = {}
    for k in pairs(index) do
      if k:sub(1, #want) == want then
        local key = k:sub(#ns + 2)
        if not after or key > after then keys[#keys + 1] = key end
      end
    end
    table.sort(keys)
    limit = limit or 1000
    local more = #keys > limit
    for i = #keys, limit + 1, -1 do keys[i] = nil end
    return keys, more
  end

  function E.stat(ns, key)
    local k = checkName(ns, key)
    local entry = k and index[k]
    if not entry then return nil end
    return { size = entry.size, ver = entry.ver, shards = entry.n }
  end

  ---------------------------------------------------------------------------
  -- Maintenance
  ---------------------------------------------------------------------------

  -- Read one cell from a device and return its text only if its data matches its hash.
  local function readGoodCell(name, id, hash)
    local cells = devices[name] and devices[name].load()
    yield()
    local cell = cells and cells[id]
    if not cell then return nil end
    local meta, nl = parseHeader(cell)
    local data = meta and base64.decode(cell:sub(nl + 1))
    if data and crypto.hashHex(data) == hash then return cell end
    mutate(name, nil, { id }) -- damaged copy: remove it so it is not counted any more
    return nil
  end

  -- Make sure every shard of k has enough copies. Returns copies created, and true if the key is lost.
  local function repair(k)
    local entry = resolve(k)
    if not entry then
      -- no complete version left: if we knew this key, its data is gone
      if index[k] and not lost[k] then lost[k] = true; cacheDrop(k); return 0, true end
      return 0, false
    end
    index[k] = entry
    local want = math.min(replicas, readyCount())
    local made, gone = 0, false
    for i = 1, entry.n do
      local sh, id = entry.shards[i], cellId(k, entry.ver, i)
      if #sh.devs < want then
        local cell
        for _, name in ipairs(sh.devs) do
          cell = readGoodCell(name, id, sh.hash)
          if cell then break end
        end
        if not cell then
          gone = true
        else
          local holders = {}
          for _, name in ipairs(sh.devs) do holders[name] = true end
          for _ = #sh.devs + 1, want do
            local best
            for _, name in ipairs(order) do
              if devOk[name] and not holders[name] and deviceMax - used[name] >= #id + #cell
                  and (not best or used[name] < used[best]) then
                best = name
              end
            end
            if not best or not mutate(best, { [id] = cell }, nil, true) then break end
            holders[best] = true
            made = made + 1
          end
        end
      end
    end
    local after = resolve(k)
    if gone or not after then
      local newly = not lost[k]
      lost[k] = true
      cacheDrop(k)
      return made, newly
    end
    index[k] = after
    if not underReplicated(after) then degraded[k] = nil end
    return made, false
  end

  -- Check one device (round-robin): verify every cell, drop damaged ones, then repair any key that
  -- is short of copies. Call regularly from the server's idle loop.
  E.scrubStep = guarded(function()
    local report = { checked = 0, bad = 0, repaired = 0, lost = 0 }
    if #order == 0 then return report end
    scrubPos = scrubPos % #order + 1
    local name = order[scrubPos]
    report.device = name
    local affected = {}
    for _, meta in pairs(dir[name]) do affected[meta.k] = true end
    local cells = devices[name].load()
    yield()
    if not cells then
      devOk[name] = false
      report.error = "io"
      return report
    end
    local bad = refresh(name, cells)
    for id, meta in pairs(dir[name]) do
      report.checked = report.checked + 1
      affected[meta.k] = true
      if meta.flag == "d" then
        local data = base64.decode(cells[id]:sub((cells[id]:find("\n", 1, true)) + 1))
        if not data or crypto.hashHex(data) ~= meta.hash then bad[#bad + 1] = id end
      end
      yield()
    end
    report.bad = #bad
    if #bad > 0 then mutate(name, nil, bad) end
    for k in pairs(degraded) do affected[k] = true end
    local keys = {}
    for k in pairs(affected) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      if index[k] then
        local made, newlyLost = repair(k)
        report.repaired = report.repaired + made
        if newlyLost then report.lost = report.lost + 1 end
      end
    end
    return report
  end)

  -- Move cells from the fullest device to the emptiest until fill differs by 30 % or less.
  E.rebalance = guarded(function(maxMoves)
    maxMoves = maxMoves or 200
    local moved = 0
    while moved < maxMoves do
      local hi, lo
      for _, name in ipairs(order) do
        if devOk[name] then
          if not hi or used[name] > used[hi] then hi = name end
          if not lo or used[name] < used[lo] then lo = name end
        end
      end
      if not hi or hi == lo or (used[hi] - used[lo]) / deviceMax <= 0.3 then break end
      -- pick cells to move: not already on the target, total at most half the difference
      local budget, ids = (used[hi] - used[lo]) / 2, {}
      for id, meta in pairs(dir[hi]) do
        if not dir[lo][id] and meta.bytes <= budget and moved + #ids < maxMoves then
          ids[#ids + 1] = id
          budget = budget - meta.bytes
        end
      end
      if #ids == 0 then break end
      local cells = devices[hi].load()
      yield()
      if not cells then devOk[hi] = false; break end
      local add, keys = {}, {}
      for _, id in ipairs(ids) do
        add[id] = cells[id]
        keys[dir[hi][id].k] = true
      end
      if not mutate(lo, add, nil, true) then break end
      local removed = mutate(hi, nil, ids)
      -- the copies moved: point the index at where they are now
      for k in pairs(keys) do
        local entry = resolve(k)
        if entry then index[k] = entry end
      end
      if not removed then break end
      moved = moved + #ids
    end
    return moved
  end)

  local function resettleDevice(name)
    local keys = {}
    for _, meta in pairs(dir[name]) do keys[meta.k] = true end
    for k in pairs(keys) do
      local entry = resolve(k)
      if entry then
        index[k] = entry
        if underReplicated(entry) then degraded[k] = true end
      end
    end
  end

  -- Start using another NBT Storage block.
  E.addDevice = guarded(function(D)
    if devices[D.name] then return nil, "exists" end
    addDevice(D)
    local cells = D.load()
    if not cells then devOk[D.name] = false; return true end
    refresh(D.name, cells)
    resettleDevice(D.name)
    return true
  end)

  -- Stop using a block: its cells are copied to other devices first.
  E.removeDevice = guarded(function(name)
    if not devices[name] then return nil, "not_found" end
    local cells = devices[name].load()
    yield()
    if not cells then return nil, "io" end
    refresh(name, cells)
    -- plan a new home for every cell that would otherwise lose a copy
    local free, per = {}, {}
    for _, other in ipairs(order) do
      if other ~= name and devOk[other] then free[other] = deviceMax - used[other] end
    end
    local ids = {}
    for id in pairs(dir[name]) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local bytes, best = dir[name][id].bytes
      for _, other in ipairs(order) do
        if free[other] and free[other] >= bytes and not dir[other][id]
            and (not best or free[other] > free[best]) then
          best = other
        end
      end
      if not best then return nil, "no_space" end
      free[best] = free[best] - bytes
      per[best] = per[best] or {}
      per[best][id] = cells[id]
    end
    for _, other in ipairs(order) do
      if per[other] and not mutate(other, per[other], nil, true) then return nil, "io" end
    end
    devices[name].store({})
    local keys = {}
    for _, meta in pairs(dir[name]) do keys[meta.k] = true end
    refresh(name, {})
    devices[name], dir[name], used[name], devOk[name] = nil, nil, nil, nil
    for i, n in ipairs(order) do
      if n == name then table.remove(order, i); break end
    end
    for k in pairs(keys) do
      local entry = resolve(k)
      if entry then index[k] = entry end
    end
    return true
  end)

  function E.health()
    local h = { devices = {}, keys = 0, bytes = 0, used = 0, capacity = #order * deviceMax,
      degraded = 0, lost = 0, cacheBytes = cacheBytes }
    for _, name in ipairs(order) do
      local cells = 0
      for _ in pairs(dir[name]) do cells = cells + 1 end
      h.devices[#h.devices + 1] = { name = name, used = used[name], cells = cells,
        errors = devices[name].errors, ok = devOk[name] }
      h.used = h.used + used[name]
    end
    for k, entry in pairs(index) do
      h.keys = h.keys + 1
      h.bytes = h.bytes + entry.size
      if lost[k] then
        h.lost = h.lost + 1
      elseif underReplicated(entry) then
        h.degraded = h.degraded + 1
      end
    end
    return h
  end

  -- The index as text, to save on local disk so the next boot can skip the full scan.
  function E.snapshot()
    local lines = { "BKSNAP 1" }
    for _, name in ipairs(order) do
      local ids = {}
      for id in pairs(dir[name]) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local m = dir[name][id]
        lines[#lines + 1] = table.concat({ name, id, m.k, m.ver, m.i, m.n, m.size, m.hash, m.flag, m.bytes }, "|")
      end
    end
    return table.concat(lines, "\n") .. "\n"
  end

  -- Load a snapshot instead of scanning. Returns true, or nil if the text is not a valid snapshot
  -- (then call rebuild). A snapshot that turns out to be out of date triggers a rebuild on first miss.
  E.loadSnapshot = guarded(function(text)
    if type(text) ~= "string" or text:sub(1, 9) ~= "BKSNAP 1\n" then return nil end
    local parsed = {}
    for line in text:sub(10):gmatch("[^\n]+") do
      local name, id, k, ver, i, n, size, hash, flag, bytes = line:match(
        "^([^|]+)|(c%x+)|([a-z]+/[A-Za-z0-9_.:-]+)|(%d+)|(%d+)|(%d+)|(%d+)|([0-9a-f-]+)|([dx])|(%d+)$")
      if not name then return nil end
      parsed[#parsed + 1] = { name = name, id = id, meta = { k = k, ver = tonumber(ver), i = tonumber(i),
        n = tonumber(n), size = tonumber(size), hash = hash, flag = flag, bytes = tonumber(bytes) } }
    end
    byKey, index, lost, degraded = {}, {}, {}, {}
    for _, name in ipairs(order) do dir[name], used[name] = {}, 0 end
    for _, p in ipairs(parsed) do
      if devices[p.name] then
        dir[p.name][p.id] = p.meta
        used[p.name] = used[p.name] + p.meta.bytes
        byKey[p.meta.k] = byKey[p.meta.k] or {}
        byKey[p.meta.k][p.name .. "/" .. p.id] = { dev = p.name, id = p.id, meta = p.meta }
      end
    end
    for k in pairs(byKey) do index[k] = resolve(k) end
    fromSnapshot = true
    return true
  end)

  return E
end

return engine
]=]
F["roles/storage/main.lua"] = [=[
-- STORAGE manager program. Started by /startup.lua.
local config = require("lib.config")
local specs = require("lib.config_specs")
local crypto = require("lib.crypto")
local proto = require("lib.proto")
local bus = require("lib.bus")
local rpc = require("lib.rpc")
local log = require("lib.log")
local device = require("roles.storage.device")
local engine = require("roles.storage.engine")
local server = require("roles.storage.server")
local keys_core = require("install.keys_core")

local SNAPSHOT = "/bs/index.snap"

local cfg, cfgErr = config.load(fs, "/bs/role/config.lua", specs.storage)
if not cfg then error(cfgErr, 0) end
local keys, keyErr = keys_core.load(fs, "/bs/keys.lua")
if not keys then error(keyErr, 0) end

local modem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
    modem = peripheral.wrap(name)
    break
  end
end
if not modem then error("no wireless modem attached", 0) end

local devices = device.discover(peripheral)
if #devices == 0 then
  error("no NBT Storage found. Connect them with wired modems (right-click each modem to turn it on).", 0)
end

if not crypto.ready() then crypto.initWithTiming() end
local function clock() return os.epoch("utc") end

local L = log.new({ fs = fs, path = "/bs/log.txt", level = cfg.log.level, keepKB = cfg.log.keepKB, clock = clock })
local B = bus.new({ modem = modem, channel = proto.CH.BUS, role = "storage", instance = cfg.id,
  keys = keys, crypto = crypto, clock = clock })
local R = rpc.new({ bus = B, pull = os.pullEvent, startTimer = os.startTimer, queueEvent = os.queueEvent,
  clock = clock, onError = function(method, err) L.error("rpc", "handler crashed", { method = method, err = err }) end })

local S
local E = engine.new({
  devices = devices, crypto = crypto, replicas = cfg.replicas, shardBytes = cfg.shardBytes,
  deviceMaxBytes = cfg.deviceMaxBytes, clock = clock,
  hot = { jobs = true, players = true, config = true },
  yield = function()
    -- keep announcing ourselves during long operations, and let other coroutines run
    S.beat()
    os.queueEvent("bs_yield")
    os.pullEvent("bs_yield")
  end,
})

S = server.new({
  engine = E, rpc = R, id = cfg.id, clock = clock, log = L,
  scrubEverySecs = math.max(1, math.floor(cfg.scrubMinutes * 60 / #devices)),
  loadSnapshot = function()
    local h = fs.open(SNAPSHOT, "r")
    if not h then return nil end
    local text = h.readAll()
    h.close()
    return text
  end,
  saveSnapshot = function(text)
    -- the snapshot only speeds up boot; skip it when it would crowd the disk
    if #text > 200000 or fs.getFreeSpace("/") < #text + 50000 then
      if fs.exists(SNAPSHOT) then fs.delete(SNAPSHOT) end
      return
    end
    local h = fs.open(SNAPSHOT .. ".tmp", "w")
    h.write(text)
    h.close()
    if fs.exists(SNAPSHOT) then fs.delete(SNAPSHOT) end
    fs.move(SNAPSHOT .. ".tmp", SNAPSHOT)
  end,
})

L.info("storage", "started", { id = cfg.id, devices = #devices })
print(("Storage manager %d: %d NBT Storage blocks. Running."):format(cfg.id, #devices))
parallel.waitForAny(R.pumpLoop, function() S.loop(os.pullEvent, os.startTimer) end)
]=]
F["roles/storage/server.lua"] = [=[
-- Storage server: exposes the engine over rpc, decides which manager is primary, and runs
-- background maintenance. Everything runs in ONE coroutine (S.loop) because the engine is not
-- re-entrant.
--
-- Primary election: every manager announces itself every 2 s. A manager is primary only while it
-- has heard no manager with a lower id for 6 s. Standbys stay silent to clients.
local rpc = require("lib.rpc")

local server = {}

local PART = 32768           -- bytes per transport part
local MAX_VALUE = 4194304
local MAX_UPLOADS = 4
local UPLOAD_IDLE_MS = 60000
local BEAT_MS = 2000
local TAKEOVER_MS = 6000

function server.new(opts)
  local E, R, id, clock, log = opts.engine, opts.rpc, opts.id, opts.clock, opts.log
  local scrubEveryMs = (opts.scrubEverySecs or 5) * 1000
  local started = clock()
  local lastLower = started   -- pretend a lower id was just heard: wait before claiming primary
  local lastBeat, lastScrub = 0, started
  local primary = false
  local uploads, uploadCount = {}, 0
  local served = nil          -- last value fetched for get_part: { k, ver, value }
  local S = { dirty = false }

  local function info(msg, fields) if log then log.info("storage", msg, fields) end end

  -- Announce ourselves. Called from the loop and from inside long engine operations.
  function S.beat()
    local now = clock()
    if now - lastBeat >= BEAT_MS then
      lastBeat = now
      R.notify("storage", "hb", { id = id, primary = primary and 1 or 0 })
    end
  end

  function S.isPrimary() return primary end
  function S.uploads() return uploadCount end

  local function becomePrimary()
    primary = true
    info("became primary", { id = id })
    local snap = opts.loadSnapshot and opts.loadSnapshot()
    if not (snap and E.loadSnapshot(snap)) then E.rebuild() end
    lastScrub = clock()
  end

  local function stepDown(lower)
    primary = false
    uploads, uploadCount, served = {}, 0, nil
    info("stepped down", { id = id, lower = lower })
  end

  -- wrap a data handler so that standbys do not answer at all
  local function data(fn)
    return function(body, src, instance)
      if not primary then return rpc.NOREPLY end
      return fn(body, src, instance)
    end
  end

  local function str(v, max) return type(v) == "string" and #v <= max end

  S.handlers = {}

  function S.handlers.hb(body, src)
    if src ~= "storage" or type(body.id) ~= "number" then return end
    if body.id < id then
      lastLower = clock()
      if primary then stepDown(body.id) end
    end
  end

  S.handlers.put = data(function(body)
    if not str(body.d, PART) then return nil, "bad_request" end
    local ok, err = E.put(body.ns, body.key, body.d)
    if not ok then return nil, err end
    S.dirty = true
    return {}
  end)

  S.handlers.put_part = data(function(body, src, instance)
    local i, n = body.i, body.n
    if not str(body.d, PART) or not str(body.up, 24) or type(i) ~= "number" or type(n) ~= "number"
        or n < 1 or n > MAX_VALUE / PART or i < 1 or i > n or i % 1 ~= 0 or n % 1 ~= 0 then
      return nil, "bad_request"
    end
    local uid = src .. ":" .. instance .. ":" .. body.up
    local up = uploads[uid]
    if not up then
      if uploadCount >= MAX_UPLOADS then return nil, "busy" end
      up = { ns = body.ns, key = body.key, n = n, parts = {}, have = 0, bytes = 0 }
      uploads[uid], uploadCount = up, uploadCount + 1
    end
    if up.n ~= n or up.ns ~= body.ns or up.key ~= body.key then return nil, "bad_request" end
    up.last = clock()
    if not up.parts[i] then
      up.parts[i], up.have, up.bytes = body.d, up.have + 1, up.bytes + #body.d
    end
    if up.have < up.n then return { done = 0 } end
    uploads[uid], uploadCount = nil, uploadCount - 1
    local ok, err = E.put(up.ns, up.key, table.concat(up.parts))
    if not ok then return nil, err end
    S.dirty = true
    return { done = 1 }
  end)

  S.handlers.get_part = data(function(body)
    local i = body.i
    if type(i) ~= "number" or i < 1 or i % 1 ~= 0 then return nil, "bad_request" end
    local st = E.stat(body.ns, body.key)
    if not st then
      -- let the engine produce the right error (bad_key / not_found)
      local _, err = E.get(body.ns, body.key)
      return nil, err or "not_found"
    end
    local k = body.ns .. "/" .. body.key
    if not (served and served.k == k and served.ver == st.ver) then
      local value, err = E.get(body.ns, body.key)
      if not value then return nil, err end
      served = { k = k, ver = st.ver, value = value }
    end
    local n = math.max(1, math.ceil(#served.value / PART))
    if i > n then return nil, "bad_request" end
    return { n = n, ver = st.ver, d = served.value:sub((i - 1) * PART + 1, i * PART) }
  end)

  S.handlers.delete = data(function(body)
    local ok, err = E.delete(body.ns, body.key)
    if not ok then return nil, err end
    S.dirty = true
    served = nil
    return {}
  end)

  S.handlers.list = data(function(body)
    local limit = type(body.limit) == "number" and math.min(body.limit, 200) or 200
    local keys, more = E.list(body.ns, type(body.prefix) == "string" and body.prefix or nil,
      type(body.after) == "string" and body.after or nil, limit)
    return { keys = keys, more = more and 1 or 0 }
  end)

  S.handlers.stat = data(function(body)
    local st = E.stat(body.ns, body.key)
    if not st then return nil, "not_found" end
    return st
  end)

  S.handlers.health = data(function()
    local h = E.health()
    local bad, errors = 0, 0
    for _, d in ipairs(h.devices) do
      if not d.ok then bad = bad + 1 end
      errors = errors + d.errors
    end
    return { id = id, devices = #h.devices, devicesBad = bad, deviceErrors = errors, keys = h.keys,
      bytes = h.bytes, used = h.used, capacity = h.capacity, degraded = h.degraded, lost = h.lost }
  end)

  -- Per-device detail for the monitor room, 20 devices per page.
  S.handlers.health_devices = data(function(body)
    local from = type(body.from) == "number" and math.max(1, math.floor(body.from)) or 1
    local h, out = E.health(), {}
    for i = from, math.min(#h.devices, from + 19) do
      local d = h.devices[i]
      out[#out + 1] = { name = d.name, used = d.used, cells = d.cells, errors = d.errors, ok = d.ok and 1 or 0 }
    end
    return { devices = out, total = #h.devices }
  end)

  -- Periodic work. Call at least once a second.
  function S.tick()
    local now = clock()
    S.beat()
    if not primary and now - lastLower > TAKEOVER_MS then becomePrimary() end
    for uid, up in pairs(uploads) do
      if now - up.last > UPLOAD_IDLE_MS then uploads[uid], uploadCount = nil, uploadCount - 1 end
    end
    if primary and now - lastScrub >= scrubEveryMs then
      lastScrub = now
      local r = E.scrubStep()
      if r.bad > 0 or r.repaired > 0 or r.lost > 0 or r.error then
        S.dirty = true
        if log then log.warn("storage", "scrub", r) end
      end
    end
    if primary and S.dirty and opts.saveSnapshot and now - (S.lastSave or 0) > 300000 then
      S.lastSave, S.dirty = now, false
      pcall(opts.saveSnapshot, E.snapshot())
    end
  end

  -- The server's single coroutine: handle requests, then periodic work, then wait.
  function S.loop(pull, startTimer)
    while true do
      R.serveOnce(S.handlers)
      S.tick()
      local timer = startTimer(1)
      while true do
        local ev, a = pull()
        if ev == "bus_req" or (ev == "timer" and a == timer) then break end
      end
    end
  end

  return S
end

return server
]=]
F["roles/worker/config.lua"] = [=[
-- WORKER turtle config.
return {
  scanRadius = 16, -- Geo Scanner radius to use (must not exceed the server's scanBlocksMaxCostRadius)
  statusSecs = 5,  -- how often it reports progress
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
]=]
F["vendor/ccryptolib/aead.lua"] = [=[
--- The ChaCha20Poly1305AEAD authenticated encryption with associated data (AEAD) construction.

local expect   = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local packing  = require "ccryptolib.internal.packing"
local chacha20 = require "ccryptolib.chacha20"
local poly1305 = require "ccryptolib.poly1305"

local p8x1, fmt8x1 = packing.compilePack("<I8")
local u4x4, fmt4x4 = packing.compileUnpack("<I4I4I4I4")
local bxor = bit32.bxor

--- Encrypts a message.
--- @param key string A 32-byte random key.
--- @param nonce string A 12-byte per-message unique nonce.
--- @param message string The message to be encrypted.
--- @param aad string aad Arbitrary associated data to also authenticate.
--- @param rounds number? The number of ChaCha20 rounds to use. Defaults to 20.
--- @return string ctx The ciphertext.
--- @return string tag The 16-byte authentication tag.
local function encrypt(key, nonce, message, aad, rounds)
    expect(1, key, "string")
    lassert(#key == 32, "key length must be 32", 2)
    expect(2, nonce, "string")
    lassert(#nonce == 12, "nonce length must be 12", 2)
    expect(3, message, "string")
    expect(4, aad, "string")
    rounds = expect(5, rounds, "number", "nil") or 20
    lassert(rounds % 2 == 0, "round number must be even", 2)
    lassert(rounds >= 8, "round number must be no smaller than 8", 2)
    lassert(rounds <= 20, "round number must be no larger than 20", 2)

    -- Generate auth key and encrypt.
    local msgLong = ("\0"):rep(64) .. message
    local ctxLong = chacha20.crypt(key, nonce, msgLong, rounds, 0)
    local authKey = ctxLong:sub(1, 32)
    local ciphertext = ctxLong:sub(65)

    -- Authenticate.
    local pad1 = ("\0"):rep(-#aad % 16)
    local pad2 = ("\0"):rep(-#ciphertext % 16)
    local aadLen = p8x1("<I8", #aad)
    local ctxLen = p8x1("<I8", #ciphertext)
    local combined = aad .. pad1 .. ciphertext .. pad2 .. aadLen .. ctxLen
    local tag = poly1305.mac(authKey, combined)

    return ciphertext, tag
end

--- Decrypts a message.
--- @param key string The key used on encryption.
--- @param nonce string The nonce used on encryption.
--- @param tag string The authentication tag returned on encryption.
--- @param ciphertext string The ciphertext to be decrypted.
--- @param aad string The arbitrary associated data used on encryption.
--- @param rounds number The number of rounds used on encryption.
--- @return string? msg The decrypted plaintext. Or nil on auth failure.
local function decrypt(key, nonce, tag, ciphertext, aad, rounds)
    expect(1, key, "string")
    lassert(#key == 32, "key length must be 32", 2)
    expect(2, nonce, "string")
    lassert(#nonce == 12, "nonce length must be 12", 2)
    expect(3, tag, "string")
    lassert(#tag == 16, "tag length must be 16", 2)
    expect(4, ciphertext, "string")
    expect(5, aad, "string")
    rounds = expect(6, rounds, "number", "nil") or 20
    lassert(rounds % 2 == 0, "round number must be even", 2)
    lassert(rounds >= 8, "round number must be no smaller than 8", 2)
    lassert(rounds <= 20, "round number must be no larger than 20", 2)

    -- Generate auth key.
    local authKey = chacha20.crypt(key, nonce, ("\0"):rep(32), rounds, 0)

    -- Check tag.
    local pad1 = ("\0"):rep(-#aad % 16)
    local pad2 = ("\0"):rep(-#ciphertext % 16)
    local aadLen = p8x1(fmt8x1, #aad)
    local ctxLen = p8x1(fmt8x1, #ciphertext)
    local combined = aad .. pad1 .. ciphertext .. pad2 .. aadLen .. ctxLen
    local t1, t2, t3, t4 = u4x4(fmt4x4, tag, 1)
    local u1, u2, u3, u4 = u4x4(fmt4x4, poly1305.mac(authKey, combined), 1)
    local eq = bxor(t1, u1) + bxor(t2, u2) + bxor(t3, u3) + bxor(t4, u4)
    if eq ~= 0 then return nil end

    -- Decrypt
    return chacha20.crypt(key, nonce, ciphertext, rounds)
end

return {
    encrypt = encrypt,
    decrypt = decrypt,
}
]=]
F["vendor/ccryptolib/blake3.lua"] = [=[
--- The BLAKE3 cryptographic hash function.

local expect = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local packing = require "ccryptolib.internal.packing"

local unpack = unpack or table.unpack
local bxor = bit32.bxor
local rol = bit32.lrotate
local p16x4, fmt16x4 = packing.compilePack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4")
local u16x4 = packing.compileUnpack(fmt16x4)
local u8x4, fmt8x4 = packing.compileUnpack("<I4I4I4I4I4I4I4I4")

local CHUNK_START = 0x01
local CHUNK_END = 0x02
local PARENT = 0x04
local ROOT = 0x08
local KEYED_HASH = 0x10
local DERIVE_KEY_CONTEXT = 0x20
local DERIVE_KEY_MATERIAL = 0x40

local IV = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local function compress(h, msg, t, v14, v15, full)
    local h00, h01, h02, h03, h04, h05, h06, h07 = unpack(h)
    local v00, v01, v02, v03 = h00, h01, h02, h03
    local v04, v05, v06, v07 = h04, h05, h06, h07
    local v08, v09, v10, v11 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local v12 = t % 2 ^ 32
    local v13 = (t - v12) * 2 ^ -32

    local m00, m01, m02, m03, m04, m05, m06, m07,
          m08, m09, m10, m11, m12, m13, m14, m15 = unpack(msg)

    local tmp
    for i = 1, 7 do
        v00 = v00 + v04 + m00 v12 = rol(bxor(v12, v00), 16)
        v08 = v08 + v12       v04 = rol(bxor(v04, v08), 20)
        v00 = v00 + v04 + m01 v12 = rol(bxor(v12, v00), 24)
        v08 = v08 + v12       v04 = rol(bxor(v04, v08), 25)

        v01 = v01 + v05 + m02 v13 = rol(bxor(v13, v01), 16)
        v09 = v09 + v13       v05 = rol(bxor(v05, v09), 20)
        v01 = v01 + v05 + m03 v13 = rol(bxor(v13, v01), 24)
        v09 = v09 + v13       v05 = rol(bxor(v05, v09), 25)

        v02 = v02 + v06 + m04 v14 = rol(bxor(v14, v02), 16)
        v10 = v10 + v14       v06 = rol(bxor(v06, v10), 20)
        v02 = v02 + v06 + m05 v14 = rol(bxor(v14, v02), 24)
        v10 = v10 + v14       v06 = rol(bxor(v06, v10), 25)

        v03 = v03 + v07 + m06 v15 = rol(bxor(v15, v03), 16)
        v11 = v11 + v15       v07 = rol(bxor(v07, v11), 20)
        v03 = v03 + v07 + m07 v15 = rol(bxor(v15, v03), 24)
        v11 = v11 + v15       v07 = rol(bxor(v07, v11), 25)

        v00 = v00 + v05 + m08 v15 = rol(bxor(v15, v00), 16)
        v10 = v10 + v15       v05 = rol(bxor(v05, v10), 20)
        v00 = v00 + v05 + m09 v15 = rol(bxor(v15, v00), 24)
        v10 = v10 + v15       v05 = rol(bxor(v05, v10), 25)

        v01 = v01 + v06 + m10 v12 = rol(bxor(v12, v01), 16)
        v11 = v11 + v12       v06 = rol(bxor(v06, v11), 20)
        v01 = v01 + v06 + m11 v12 = rol(bxor(v12, v01), 24)
        v11 = v11 + v12       v06 = rol(bxor(v06, v11), 25)

        v02 = v02 + v07 + m12 v13 = rol(bxor(v13, v02), 16)
        v08 = v08 + v13       v07 = rol(bxor(v07, v08), 20)
        v02 = v02 + v07 + m13 v13 = rol(bxor(v13, v02), 24)
        v08 = v08 + v13       v07 = rol(bxor(v07, v08), 25)

        v03 = v03 + v04 + m14 v14 = rol(bxor(v14, v03), 16)
        v09 = v09 + v14       v04 = rol(bxor(v04, v09), 20)
        v03 = v03 + v04 + m15 v14 = rol(bxor(v14, v03), 24)
        v09 = v09 + v14       v04 = rol(bxor(v04, v09), 25)

        if i ~= 7 then
            tmp = m02
            m02 = m03
            m03 = m10
            m10 = m12
            m12 = m09
            m09 = m11
            m11 = m05
            m05 = m00
            m00 = tmp

            tmp = m06
            m06 = m04
            m04 = m07
            m07 = m13
            m13 = m14
            m14 = m15
            m15 = m08
            m08 = m01
            m01 = tmp
        end
    end

    if full then
        return {
            bxor(v00, v08), bxor(v01, v09), bxor(v02, v10), bxor(v03, v11),
            bxor(v04, v12), bxor(v05, v13), bxor(v06, v14), bxor(v07, v15),
            bxor(v08, h00), bxor(v09, h01), bxor(v10, h02), bxor(v11, h03),
            bxor(v12, h04), bxor(v13, h05), bxor(v14, h06), bxor(v15, h07),
        }
    else
        return {
            bxor(v00, v08), bxor(v01, v09), bxor(v02, v10), bxor(v03, v11),
            bxor(v04, v12), bxor(v05, v13), bxor(v06, v14), bxor(v07, v15),
        }
    end
end

local function merge(cvl, cvr)
    for i = 1, 8 do cvl[i + 8] = cvr[i] end
    return cvl
end

local function blake3(iv, flags, msg, len)
    -- Set up the state.
    local stateCvs = {}
    local stateCv = iv
    local stateT = 0
    local stateN = 0
    local stateStart = CHUNK_START
    local stateEnd = 0

    -- Digest complete blocks.
    for i = 1, #msg - 64, 64 do
        -- Compress the block.
        local block = {u16x4(fmt16x4, msg, i)}
        local stateFlags = flags + stateStart + stateEnd
        stateCv = compress(stateCv, block, stateT, 64, stateFlags)
        stateStart = 0
        stateN = stateN + 1

        if stateN == 15 then
            -- Last block in chunk.
            stateEnd = CHUNK_END
        elseif stateN == 16 then
            -- Chunk complete, merge.
            local mergeCv = stateCv
            local mergeAmt = stateT + 1
            while mergeAmt % 2 == 0 do
                local block = merge(table.remove(stateCvs), mergeCv)
                mergeCv = compress(iv, block, 0, 64, flags + PARENT)
                mergeAmt = mergeAmt / 2
            end

            -- Push back.
            table.insert(stateCvs, mergeCv)

            -- Update state back to next chunk.
            stateCv = iv
            stateT = stateT + 1
            stateN = 0
            stateStart = CHUNK_START
            stateEnd = 0
        end
    end

    -- Pad the last message block.
    local lastLen = #msg == 0 and 0 or (#msg - 1) % 64 + 1
    local padded = msg:sub(-lastLen) .. ("\0"):rep(64)
    local last = {u16x4(fmt16x4, padded, 1)}

    -- Prepare output expansion state.
    local outCv, outBlock, outLen, outFlags
    if stateT > 0 then
        -- Root is a parent, digest last block now and merge parents.
        local stateFlags = flags + stateStart + CHUNK_END
        local mergeCv = compress(stateCv, last, stateT, lastLen, stateFlags)
        for i = #stateCvs, 2, -1 do
            local block = merge(stateCvs[i], mergeCv)
            mergeCv = compress(iv, block, 0, 64, flags + PARENT)
        end

        -- Set output state.
        outCv = iv
        outBlock = merge(stateCvs[1], mergeCv)
        outLen = 64
        outFlags = flags + ROOT + PARENT
    else
        -- Root block is in the first chunk, set output state.
        outCv = stateCv
        outBlock = last
        outLen = lastLen
        outFlags = flags + stateStart + CHUNK_END + ROOT
    end

    -- Expand output.
    local out = {}
    for i = 0, len / 64 do
        local md = compress(outCv, outBlock, i, outLen, outFlags, true)
        out[i + 1] = p16x4(fmt16x4, unpack(md))
    end

    return table.concat(out):sub(1, len)
end

--- Hashes data using BLAKE3.
--- @param message string The input message.
--- @param len number? The desired hash length, in bytes. Defaults to 32.
--- @return string hash The hash.
local function digest(message, len)
    expect(1, message, "string")
    len = expect(2, len, "number", "nil") or 32
    lassert(len % 1 == 0, "desired output length must be an integer", 2)
    lassert(len >= 1, "desired output length must be positive", 2)
    return blake3(IV, 0, message, len)
end

--- Performs a keyed hash.
--- @param key string A 32-byte random key.
--- @param message string The input message.
--- @param len number? The desired hash length, in bytes. Defaults to 32.
--- @return string hash The keyed hash.
local function digestKeyed(key, message, len)
    expect(1, key, "string")
    lassert(#key == 32, "key length must be 32", 2)
    expect(2, message, "string")
    len = expect(3, len, "number", "nil") or 32
    lassert(len % 1 == 0, "desired output length must be an integer", 2)
    lassert(len >= 1, "desired output length must be positive", 2)
    return blake3({u8x4(fmt8x4, key, 1)}, KEYED_HASH, message, len)
end

--- Makes a context-based key derivation function (KDF).
--- @param context string The context for the KDF.
--- @return fun(material: string, len: number?): string kdf The KDF.
local function deriveKey(context)
    expect(1, context, "string")
    local iv = {u8x4(fmt8x4, blake3(IV, DERIVE_KEY_CONTEXT, context, 32), 1)}

    --- Derives a key.
    --- @param material string The keying material.
    --- @param len number? The desired hash length, in bytes. Defaults to 32.
    return function(material, len)
        expect(1, material, "string")
        len = expect(2, len, "number", "nil") or 32
        lassert(len % 1 == 0, "desired output length must be an integer", 2)
        lassert(len >= 1, "desired output length must be positive", 2)
        return blake3(iv, DERIVE_KEY_MATERIAL, material, len)
    end
end

return {
    digest = digest,
    digestKeyed = digestKeyed,
    deriveKey = deriveKey,
}
]=]
F["vendor/ccryptolib/chacha20.lua"] = [=[
--- The ChaCha20 stream cipher.

local expect  = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local packing = require "ccryptolib.internal.packing"

local bxor = bit32.bxor
local rol = bit32.lrotate
local u8x4, fmt8x4 = packing.compileUnpack("<I4I4I4I4I4I4I4I4")
local u3x4, fmt3x4 = packing.compileUnpack("<I4I4I4")
local p16x4, fmt16x4 = packing.compilePack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4")
local u16x4 = packing.compileUnpack(fmt16x4)

--- Encrypts/Decrypts data using ChaCha20.
--- @param key string A 32-byte random key.
--- @param nonce string A 12-byte per-message unique nonce.
--- @param message string A plaintext or ciphertext.
--- @param rounds number? The number of ChaCha20 rounds to use. Defaults to 20.
--- @param offset number? The block offset to generate the keystream at. Defaults to 1.
--- @return string out The resulting ciphertext or plaintext.
local function crypt(key, nonce, message, rounds, offset)
    expect(1, key, "string")
    lassert(#key == 32, "key length must be 32", 2)
    expect(2, nonce, "string")
    lassert(#nonce == 12, "nonce length must be 12", 2)
    expect(3, message, "string")
    rounds = expect(4, rounds, "number", "nil") or 20
    lassert(rounds % 2 == 0, "round number must be even", 2)
    lassert(rounds >= 8, "round number must be no smaller than 8", 2)
    lassert(rounds <= 20, "round number must be no larger than 20", 2)
    offset = expect(5, offset, "number", "nil") or 1
    lassert(offset % 1 == 0, "offset must be an integer", 2)
    lassert(offset >= 0, "offset must be nonnegative", 2)
    lassert(#message + 64 * offset <= 2 ^ 38, "offset too large", 2)

    -- Build the state block.
    local i0, i1, i2, i3 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
    local k0, k1, k2, k3, k4, k5, k6, k7 = u8x4(fmt8x4, key, 1)
    local cr, n0, n1, n2 = offset, u3x4(fmt3x4, nonce, 1)

    -- Pad the message.
    local padded = message .. ("\0"):rep(-#message % 64)

    -- Expand and combine.
    local out = {}
    local idx = 1
    for i = 1, #padded / 64 do
        -- Copy the block.
        local s00, s01, s02, s03 = i0, i1, i2, i3
        local s04, s05, s06, s07 = k0, k1, k2, k3
        local s08, s09, s10, s11 = k4, k5, k6, k7
        local s12, s13, s14, s15 = cr, n0, n1, n2

        -- Iterate.
        for _ = 1, rounds, 2 do
            s00 = s00 + s04 s12 = rol(bxor(s12, s00), 16)
            s08 = s08 + s12 s04 = rol(bxor(s04, s08), 12)
            s00 = s00 + s04 s12 = rol(bxor(s12, s00), 8)
            s08 = s08 + s12 s04 = rol(bxor(s04, s08), 7)

            s01 = s01 + s05 s13 = rol(bxor(s13, s01), 16)
            s09 = s09 + s13 s05 = rol(bxor(s05, s09), 12)
            s01 = s01 + s05 s13 = rol(bxor(s13, s01), 8)
            s09 = s09 + s13 s05 = rol(bxor(s05, s09), 7)

            s02 = s02 + s06 s14 = rol(bxor(s14, s02), 16)
            s10 = s10 + s14 s06 = rol(bxor(s06, s10), 12)
            s02 = s02 + s06 s14 = rol(bxor(s14, s02), 8)
            s10 = s10 + s14 s06 = rol(bxor(s06, s10), 7)

            s03 = s03 + s07 s15 = rol(bxor(s15, s03), 16)
            s11 = s11 + s15 s07 = rol(bxor(s07, s11), 12)
            s03 = s03 + s07 s15 = rol(bxor(s15, s03), 8)
            s11 = s11 + s15 s07 = rol(bxor(s07, s11), 7)

            s00 = s00 + s05 s15 = rol(bxor(s15, s00), 16)
            s10 = s10 + s15 s05 = rol(bxor(s05, s10), 12)
            s00 = s00 + s05 s15 = rol(bxor(s15, s00), 8)
            s10 = s10 + s15 s05 = rol(bxor(s05, s10), 7)

            s01 = s01 + s06 s12 = rol(bxor(s12, s01), 16)
            s11 = s11 + s12 s06 = rol(bxor(s06, s11), 12)
            s01 = s01 + s06 s12 = rol(bxor(s12, s01), 8)
            s11 = s11 + s12 s06 = rol(bxor(s06, s11), 7)

            s02 = s02 + s07 s13 = rol(bxor(s13, s02), 16)
            s08 = s08 + s13 s07 = rol(bxor(s07, s08), 12)
            s02 = s02 + s07 s13 = rol(bxor(s13, s02), 8)
            s08 = s08 + s13 s07 = rol(bxor(s07, s08), 7)

            s03 = s03 + s04 s14 = rol(bxor(s14, s03), 16)
            s09 = s09 + s14 s04 = rol(bxor(s04, s09), 12)
            s03 = s03 + s04 s14 = rol(bxor(s14, s03), 8)
            s09 = s09 + s14 s04 = rol(bxor(s04, s09), 7)
        end

        -- Decode message block.
        local m00, m01, m02, m03, m04, m05, m06, m07
        local m08, m09, m10, m11, m12, m13, m14, m15

        m00, m01, m02, m03, m04, m05, m06, m07,
        m08, m09, m10, m11, m12, m13, m14, m15, idx =
            u16x4(fmt16x4, padded, idx)

        -- Feed-forward and combine.
        out[i] = p16x4(fmt16x4,
            bxor(m00, s00 + i0), bxor(m01, s01 + i1),
            bxor(m02, s02 + i2), bxor(m03, s03 + i3),
            bxor(m04, s04 + k0), bxor(m05, s05 + k1),
            bxor(m06, s06 + k2), bxor(m07, s07 + k3),
            bxor(m08, s08 + k4), bxor(m09, s09 + k5),
            bxor(m10, s10 + k6), bxor(m11, s11 + k7),
            bxor(m12, s12 + cr), bxor(m13, s13 + n0),
            bxor(m14, s14 + n1), bxor(m15, s15 + n2)
        )

        -- Increment counter.
        cr = cr + 1
    end

    return table.concat(out):sub(1, #message)
end

return {
    crypt = crypt,
}
]=]
F["vendor/ccryptolib/config.lua"] = [=[
local expect = require "cc.expect".expect

local usePeripheralsValue = true

--- Sets whether to use peripheral calls for computation. Defaults to true.
---
--- If this is true, ccryptolib will search for compatible peripherals every few
--- seconds. If a compatible peripheral is found, ccryptolib will offload some
--- of its computation to it, improving performance.
---
--- No peripheral searches are performed until you first call a ccryptolib
--- function. Setting this value to false beforehand guarantees no searches will
--- ever be made.
---
--- @param value boolean? The new setting. If nil then no changes are made.
--- @return boolean value The current setting. Includes any changes made.
local function usePeripherals(value)
    expect(1, value, "boolean", "nil")
    if value ~= nil then usePeripheralsValue = value end
    return usePeripheralsValue
end

return {
    usePeripherals = usePeripherals,
}
]=]
F["vendor/ccryptolib/ed25519.lua"] = [=[
--- The Ed25519 digital signature scheme.

local expect = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local hw = require "ccryptolib.internal.hw"
local fq = require "ccryptolib.internal.fq"
local sha512 = require "ccryptolib.internal.sha512"
local ed = require "ccryptolib.internal.edwards25519"
local random = require "ccryptolib.random"

--- Computes a public key from a secret key.
--- @param sk string A random 32-byte secret key.
--- @return string pk The matching 32-byte public key.
local function publicKey(sk)
    expect(1, sk, "string")
    assert(#sk == 32, "secret key length must be 32")
    local ok, out = hw.ed25519PublicKey(sk)
    if ok then return out end

    local h = sha512.digest(sk)
    local x = fq.decodeClamped(h:sub(1, 32))

    return ed.encode(ed.mulG(fq.bits(x)))
end

--- Signs a message.
--- @param sk string The signer's secret key.
--- @param pk string The signer's public key.
--- @param msg string The message to be signed.
--- @return string sig The 64-byte signature on the message.
local function sign(sk, pk, msg)
    expect(1, sk, "string")
    lassert(#sk == 32, "secret key length must be 32", 2)
    expect(2, pk, "string")
    lassert(#pk == 32, "public key length must be 32", 2)
    expect(3, msg, "string")

    -- Note: We use randomization as a side channel attack mitigation attempt.
    -- Calls to other libraries will almost surely use the standardized
    -- deterministic signatues instead.
    local ok, out = hw.ed25519Sign(msg, sk)
    if ok then return out end

    -- Secret key.
    local h = sha512.digest(sk)
    local x = fq.decodeClamped(h:sub(1, 32))

    -- Commitment.
    local k = fq.decodeWide(random.random(64))
    local r = ed.mulG(fq.bits(k))
    local rStr = ed.encode(r)

    -- Challenge.
    local e = fq.decodeWide(sha512.digest(rStr .. pk .. msg))

    -- Response.
    local m = fq.decodeWide(random.random(64))
    local s = fq.sub(fq.add(k, fq.mul(fq.add(x, m), e)), fq.mul(m, e))
    local sStr = fq.encode(s)

    return rStr .. sStr
end

--- Verifies a signature on a message.
--- @param pk string The signer's public key.
--- @param msg string The signed message.
--- @param sig string The alleged signature.
--- @return boolean valid Whether the signature is valid or not.
local function verify(pk, msg, sig)
    expect(1, pk, "string")
    lassert(#pk == 32, "public key length must be 32", 2) --- @cast pk String32
    expect(2, msg, "string")
    expect(3, sig, "string")
    lassert(#sig == 64, "signature length must be 64", 2)

    -- Note: The library verifier may use strict signature verification, which
    -- rejects signatures that we don't with some adversarial signatures. We
    -- make no guarantees on those so we can get by regardless.
    local ok, out = hw.ed25519Verify(msg, sig, pk)
    if ok then return out end

    local y = ed.decode(pk)
    if not y then return false end

    local rStr = sig:sub(1, 32)
    local sStr = sig:sub(33)

    local e = fq.decodeWide(sha512.digest(rStr .. pk .. msg))

    local gs = ed.mulG(fq.bits(fq.decode(sStr)))
    local ye = ed.mul(y, fq.bits(e))
    local rv = ed.sub(gs, ed.niels(ye))

    return ed.encode(rv) == rStr
end

return {
    publicKey = publicKey,
    sign = sign,
    verify = verify,
}
]=]
F["vendor/ccryptolib/internal/curve25519.lua"] = [=[
--- Point arithmetic on the Curve25519 Montgomery curve.

local fp = require "ccryptolib.internal.fp"
local ed = require "ccryptolib.internal.edwards25519"
local random = require "ccryptolib.random"

--- @class MtPoint A point class on Curve25519, in XZ coordinates.
--- @field [1] number[] The X coordinate.
--- @field [2] number[] The Z coordinate.

--- Doubles a point.
--- @param P1 MtPoint The point to double.
--- @return MtPoint P2 P1 + P1.
local function double(P1)
    local x1, z1 = P1[1], P1[2]
    local a = fp.add(x1, z1)
    local aa = fp.square(a)
    local b = fp.sub(x1, z1)
    local bb = fp.square(b)
    local c = fp.sub(aa, bb)
    local x3 = fp.mul(aa, bb)
    local z3 = fp.mul(c, fp.add(bb, fp.kmul(c, 121666)))
    return {x3, z3}
end

--- Computes differential addition on two points.
--- @param DP MtPoint P1 - P2.
--- @param P1 MtPoint The first point to add.
--- @param P2 MtPoint The second point to add.
--- @return MtPoint P3 P1 + P2.
local function dadd(DP, P1, P2)
    local dx, dz = DP[1], DP[2]
    local x1, z1 = P1[1], P1[2]
    local x2, z2 = P2[1], P2[2]
    local a = fp.add(x1, z1)
    local b = fp.sub(x1, z1)
    local c = fp.add(x2, z2)
    local d = fp.sub(x2, z2)
    local da = fp.mul(d, a)
    local cb = fp.mul(c, b)
    local x3 = fp.mul(dz, fp.square(fp.add(da, cb)))
    local z3 = fp.mul(dx, fp.square(fp.sub(da, cb)))
    return {x3, z3}
end

--- Performs a step on the Montgomery ladder.
--- @param DP MtPoint P1 - P2.
--- @param P1 MtPoint The first point.
--- @param P2 MtPoint The second point.
--- @return MtPoint P3 2A
--- @return MtPoint P4 A + B
local function step(DP, P1, P2)
    local dx, dz = DP[1], DP[2]
    local x1, z1 = P1[1], P1[2]
    local x2, z2 = P2[1], P2[2]
    local a = fp.add(x1, z1)
    local aa = fp.square(a)
    local b = fp.sub(x1, z1)
    local bb = fp.square(b)
    local e = fp.sub(aa, bb)
    local c = fp.add(x2, z2)
    local d = fp.sub(x2, z2)
    local da = fp.mul(d, a)
    local cb = fp.mul(c, b)
    local x4 = fp.mul(dz, fp.square(fp.add(da, cb)))
    local z4 = fp.mul(dx, fp.square(fp.sub(da, cb)))
    local x3 = fp.mul(aa, bb)
    local z3 = fp.mul(e, fp.add(bb, fp.kmul(e, 121666)))
    return {x3, z3}, {x4, z4}
end

local function ladder(DP, bits)
    local P = {fp.num(1), fp.num(0)}
    local Q = DP

    for i = #bits, 1, -1 do
        if bits[i] == 0 then
            P, Q = step(DP, P, Q)
        else
            Q, P = step(DP, Q, P)
        end
    end

    return P
end

--- Performs a scalar multiplication operation with multiplication by 8.
--- @param P MtPoint The base point.
--- @param bits number[] The scalar multiplier, in little-endian bits.
--- @return MtPoint product The product, multiplied by 8.
local function ladder8(P, bits)
    -- Randomize.
    local rf = fp.decode(random.random(32) --[[@as String32, length is given]])
    P = {fp.mul(P[1], rf), fp.mul(P[2], rf)}

    -- Multiply.
    return double(double(double(ladder(P, bits))))
end

--- Scales a point's coordinates.
--- @param P MtPoint The input point.
--- @return MtPoint Q The same point P, but with Z = 1.
local function scale(P)
    return {fp.mul(P[1], fp.invert(P[2])), fp.num(1)}
end

--- Encodes a scaled point.
--- @param P MtPoint The scaled point to encode.
--- @return string encoded P, encoded into a 32-byte string.
local function encode(P)
    return fp.encode(P[1])
end

--- Decodes a point.
--- @param str String32 A 32-byte encoded point.
--- @return MtPoint pt The decoded point.
local function decode(str)
    return {fp.decode(str), fp.num(1)}
end

--- Decodes an Edwards25519 encoded point into Curve25519, ignoring the sign.
---
--- There is a single exception: The identity point (0, 1), which gets mapped
--- into the 2-torsion point (0, 0), which isn't the identity of Curve25519.
---
--- @param str String32 A 32-byte encoded Edwards25519 point.
--- @return MtPoint pt The decoded point, mapped into Curve25519.
local function decodeEd(str)
    local y = fp.decode(str)
    local n = fp.carry(fp.add(fp.num(1), y))
    local d = fp.carry(fp.sub(fp.num(1), y))
    if fp.eqz(d) then
        return {fp.num(0), fp.num(1)}
    else
        return {n, d}
    end
end

--- Performs a scalar multiplication by the base point G.
--- @param bits number[] The scalar multiplier, in little-endian bits.
--- @return MtPoint product The product point.
local function mulG(bits)
    -- Multiply by G on Edwards25519.
    local P = ed.mulG(bits)

    -- Use the birational map to get the point on Curve25519.
    -- Never fails since G is in the large group, and the exponent is clamped.
    local Py, Pz = P[2], P[3]
    local Rx = fp.carry(fp.add(Py, Pz))
    local Rz = fp.carry(fp.sub(Pz, Py))

    return {Rx, Rz}
end

--- Computes a twofold product from a ruleset.
---
--- Returns nil if any of the results would be equal to the identity.
---
--- @param P MtPoint The base point.
--- @param ruleset __TYPE_TODO The ruleset generated by scalars m, n.
--- @return MtPoint? A [8m]P.
--- @return MtPoint? B [8n]P.
--- @return MtPoint? C [8m]P - [8n]P.
local function prac(P, ruleset)
    -- Randomize.
    local rf = fp.decode(random.random(32) --[[@as String32, length is given]])
    local A = {fp.mul(P[1], rf), fp.mul(P[2], rf)}

    -- Start the base at [8]P.
    local A = double(double(double(A)))

    -- Throw away small order points.
    if fp.eqz(A[2]) then return end

    -- Now e = d = gcd(m, n).
    -- Update A from [8]P to [8 * gcd(m, n)]P.
    A = ladder(A, ruleset[1])

    -- Reject rulesets where m = n.
    local rules = ruleset[2]
    if #rules == 0 then return end

    -- Evaluate the first rule.
    -- Since e = d, this means A - B = C = O. Differential addition fails when
    -- C = O, so we need to treat this case specially.
    -- Note that rules 0 and 1 never happen last, since the algorithm would stop
    -- one step earlier if they did:
    -- - If after rule 0 we had e = d, then (d, e) → (e, d) would also mean that
    --   e = d, so it stops one step earlier.
    -- - If after rule 1 we had e = d, then (d, e) → ((2d - e)/3, (2e - d)/3)
    --   would mean that (2d - e)/3 = (2e - d)/3, thus 2d - e = 2e - d, thus
    --   3d = 3e, thus d = e, so it stops one step earlier.
    local B, C
    local rule = rules[#rules]
    if rule == 2 then
        -- (A, B, C) ← (2A + B, B, 2A) = (3A, A, 2A)
        local A2 = double(A)
        A, B, C = dadd(A, A2, A), A, A2
    elseif rule == 3 or rule == 5 then
        -- (A, B, C) ← (A + B, B, A) = (2A, A, A)
        -- or (A, B, C) ← (2A, B, 2A - B) = (2A, A, A)
        A, B, C = double(A), A, A
    elseif rule == 6 then
        -- (A, B, C) ← (3A + 3B, B, 3A + 2B) = (6A, A, 5A)
        local A2 = double(A)
        local A3 = dadd(A, A2, A)
        A, B, C = double(A3), A, dadd(A, A3, A2)
    elseif rule == 7 then
        -- (A, B, C) ← (3A + 2B, B, 3A + B) = (5A, A, 4A)
        local A2 = double(A)
        local A3 = dadd(A, A2, A)
        local A4 = double(A2)
        A, B, C = dadd(A3, A4, A), A, A4
    elseif rule == 8 then
        -- (A, B, C) ← (3A + B, B, 3A) = (4A, A, 3A)
        local A2 = double(A)
        local A3 = dadd(A, A2, A)
        A, B, C = double(A2), A, A3
    else
        -- (A, B, C) ← (A, 2B, A - 2B) = (A, 2A, A)
        A, B, C = A, double(A), A
    end

    -- Evaluate the other rules.
    -- Let's assume addition is undefined here, this happens when A - B = O.
    -- Since A = [d]P and B = [e]P, A = B happens when:
    -- (1) P is on the large order base group and d ≡ e (mod q).
    -- (2) P is on the large order twist group and d ≡ e (mod q').
    -- (3) P is on a small order group.
    -- Case (3) never happens since we throw small order points away above.
    -- Since 0 ≤ {d, e} < q < q', a modular equivalence here means an integer
    -- equivalence. Therefore d = e.
    -- However, the ruleset stops when d = e, therefore the algorithm must have
    -- stopped earlier than when it did. Contradiction.
    -- Therefore, addition is always defined.
    -- Furthermore, the PRAC invariants mean that this product is the same as
    -- if the points were multiplied separately.
    for i = #rules - 1, 1, -1 do
        local rule = rules[i]
        if rule == 0 then
            -- (A, B, C) ← (B, A, B - A)
            A, B = B, A
        elseif rule == 1 then
            -- (A, B, C) ← (2A + B, A + 2B, A - B)
            local AB = dadd(C, A, B)
            A, B = dadd(B, AB, A), dadd(A, AB, B)
        elseif rule == 2 then
            -- (A, B, C) ← (2A + B, B, 2A)
            A, C = dadd(B, dadd(C, A, B), A), double(A)
        elseif rule == 3 then
            -- (A, B, C) ← (A + B, B, A)
            A, C = dadd(C, A, B), A
        elseif rule == 5 then
            -- (A, B, C) ← (2A, B, 2A - B)
            A, C = double(A), dadd(B, A, C)
        elseif rule == 6 then
            -- (A, B, C) ← (3A + 3B, B, 3A + 2B)
            local AB = dadd(C, A, B)
            local AABB = double(AB)
            A, C = dadd(AB, AABB, AB), dadd(dadd(A, AB, B), AABB, A)
        elseif rule == 7 then
            -- (A, B, C) ← (3A + 2B, B, 3A + B)
            local AB = dadd(C, A, B)
            local AAB = dadd(B, AB, A)
            A, C = dadd(A, AAB, AB), dadd(AB, AAB, A)
        elseif rule == 8 then
            -- (A, B, C) ← (3A + B, B, 3A)
            local AA = double(A)
            A, C = dadd(C, AA, dadd(C, A, B)), dadd(A, AA, A)
        else
            -- (A, B, C) ← (A, 2B, A - 2B)
            B, C = double(B), dadd(A, C, B)
        end
    end

    return A, B, C
end

return {
    G = {fp.num(9), fp.num(1)},
    dadd = dadd,
    scale = scale,
    encode = encode,
    decode = decode,
    decodeEd = decodeEd,
    ladder8 = ladder8,
    mulG = mulG,
    prac = prac,
}
]=]
F["vendor/ccryptolib/internal/edwards25519.lua"] = [=[
--- Point arithmetic on the Edwards25519 Edwards curve.

local fp = require "ccryptolib.internal.fp"

local unpack = unpack or table.unpack

--- @class EdPoint A point on Edwards25519, in extended coordinates.
--- @field [1] number[] The X coordinate.
--- @field [2] number[] The Y coordinate.
--- @field [3] number[] The Z coordinate.
--- @field [4] number[] The T coordinate.

--- @class NsPoint A point on Edwards25519, in Niels' coordinates.
--- @field [1] number[] Preprocessed Y + X.
--- @field [2] number[] Preprocessed Y - X.
--- @field [3] number[] Preprocessed 2Z.
--- @field [4] number[] Preprocessed 2DT.

local D = fp.mul(fp.num(-121665), fp.invert(fp.num(121666)))
local K = fp.kmul(D, 2)

--- @type EdPoint
local O = {fp.num(0), fp.num(1), fp.num(1), fp.num(0)}
local G = nil

--- Doubles a point.
--- @param P1 EdPoint The point to double.
--- @return EdPoint P2 P1 + P1.
local function double(P1)
    -- Unsoundness: fp.sub(g, e), and fp.sub(d, i) break fp.sub's contract since
    -- it doesn't accept an fp2. Although not ideal, in practice this doesn't
    -- matter since fp.carry handles the larger sum.
    local P1x, P1y, P1z = unpack(P1)
    local a = fp.square(P1x)
    local b = fp.square(P1y)
    local c = fp.square(P1z)
    local d = fp.add(c, c)
    local e = fp.add(a, b)
    local f = fp.add(P1x, P1y)
    local g = fp.square(f)
    local h = fp.carry(fp.sub(g, e))
    local i = fp.sub(b, a)
    local j = fp.carry(fp.sub(d, i))
    local P3x = fp.mul(h, j)
    local P3y = fp.mul(i, e)
    local P3z = fp.mul(j, i)
    local P3t = fp.mul(h, e)
    return {P3x, P3y, P3z, P3t}
end

--- Adds two points.
--- @param P1 EdPoint The first summand point.
--- @param N2 NsPoint The second summand point.
--- @return EdPoint P3 P1 + P2, where N2 = niels(P2).
local function add(P1, N2)
    local P1x, P1y, P1z, P1t = unpack(P1)
    local N1p, N1m, N1z, N1t = unpack(N2)
    local a = fp.sub(P1y, P1x)
    local b = fp.mul(a, N1m)
    local c = fp.add(P1y, P1x)
    local d = fp.mul(c, N1p)
    local e = fp.mul(P1t, N1t)
    local f = fp.mul(P1z, N1z)
    local g = fp.sub(d, b)
    local h = fp.sub(f, e)
    local i = fp.add(f, e)
    local j = fp.add(d, b)
    local P3x = fp.mul(g, h)
    local P3y = fp.mul(i, j)
    local P3z = fp.mul(h, i)
    local P3t = fp.mul(g, j)
    return {P3x, P3y, P3z, P3t}
end

--- Subtracts one point from another.
--- @param P1 EdPoint The first summand point.
--- @param N2 NsPoint The second summand point.
--- @return EdPoint P3 P1 - P2, where N2 = niels(P2).
local function sub(P1, N2)
    local P1x, P1y, P1z, P1t = unpack(P1)
    local N1p, N1m, N1z, N1t = unpack(N2)
    local a = fp.sub(P1y, P1x)
    local b = fp.mul(a, N1p)
    local c = fp.add(P1y, P1x)
    local d = fp.mul(c, N1m)
    local e = fp.mul(P1t, N1t)
    local f = fp.mul(P1z, N1z)
    local g = fp.sub(d, b)
    local h = fp.add(f, e)
    local i = fp.sub(f, e)
    local j = fp.add(d, b)
    local P3x = fp.mul(g, h)
    local P3y = fp.mul(i, j)
    local P3z = fp.mul(h, i)
    local P3t = fp.mul(g, j)
    return {P3x, P3y, P3z, P3t}
end

--- Computes the Niels representation of a point.
--- @param P1 EdPoint The input point.
--- @return NsPoint N1 Niels' precomputation applied to P1.
local function niels(P1)
    local P1x, P1y, P1z, P1t = unpack(P1)
    local N3p = fp.add(P1y, P1x)
    local N3m = fp.sub(P1y, P1x)
    local N3z = fp.add(P1z, P1z)
    local N3t = fp.mul(P1t, K)
    return {N3p, N3m, N3z, N3t}
end

--- Scales a point.
--- @param P1 EdPoint The input point.
--- @return EdPoint P2 The same point as P1, but with Z = 1.
local function scale(P1)
    local P1x, P1y, P1z = unpack(P1)
    local zInv = fp.invert(P1z)
    local P3x = fp.mul(P1x, zInv)
    local P3y = fp.mul(P1y, zInv)
    local P3z = fp.num(1)
    local P3t = fp.mul(P3x, P3y)
    return {P3x, P3y, P3z, P3t}
end

--- Encodes a scaled point.
--- @param P1 EdPoint The scaled point to encode.
--- @return string out P1 encoded as a 32-byte string.
local function encode(P1)
    P1 = scale(P1)
    local P1x, P1y = unpack(P1)
    local y = fp.encode(P1y)
    local xBit = fp.canonicalize(P1x)[1] % 2
    return y:sub(1, -2) .. string.char(y:byte(-1) + xBit * 128)
end

--- Decodes a point.
--- @param str String32 A 32-byte encoded point.
--- @return EdPoint? P1 The decoded point, or nil if it isn't on the curve.
local function decode(str)
    local P3y = fp.decode(str)
    local a = fp.square(P3y)
    local b = fp.sub(a, fp.num(1))
    local c = fp.mul(a, D)
    local d = fp.add(c, fp.num(1))
    local P3x = fp.sqrtDiv(b, d)
    if not P3x then return nil end
    local xBit = fp.canonicalize(P3x)[1] % 2
    if xBit ~= bit32.extract(str:byte(-1), 7) then
        P3x = fp.carry(fp.neg(P3x))
    end
    local P3z = fp.num(1)
    local P3t = fp.mul(P3x, P3y)
    return {P3x, P3y, P3z, P3t}
end

G = decode("Xfffffffffffffffffffffffffffffff") --[[@as EdPoint, G is valid]]

--- Transforms little-endian bits into a signed radix-2^w form.
--- @param bits number[]
--- @param w number Log2 of the radix, must be at least 1.
--- @return number[]
local function signedRadixW(bits, w)
    -- TODO Find a more elegant way of doing this.
    local wPow = 2 ^ w
    local wPowh = wPow / 2
    local out = {}
    local acc = 0
    local mul = 1
    for i = 1, #bits do
        acc = acc + bits[i] * mul
        mul = mul * 2
        while i == #bits and acc > 0 or mul > wPow do
            local rem = acc % wPow
            if rem >= wPowh then rem = rem - wPow end
            acc = (acc - rem) / wPow
            mul = mul / wPow
            out[#out + 1] = rem
        end
    end
    return out
end

--- Computes a multiplication table for radix-2^w form multiplication.
--- @param P EdPoint The base point.
--- @param w number Log2 of the radix, must be at least 1.
--- @return NsPoint[][]
local function radixWTable(P, w)
    local out = {}
    for i = 1, math.ceil(256 / w) do
        local row = {niels(P)}
        for j = 2, 2 ^ w / 2 do
            P = add(P, row[1])
            row[j] = niels(P)
        end
        out[i] = row
        P = double(P)
    end
    return out
end

--- The radix logarithm of the precomputed table for G.
local G_W = 5

--- The precomputed multiplication table for G.
local G_TABLE = radixWTable(G, G_W)

--- Transforms little-endian bits into a signed radix-2^w non-adjacent form.
---
--- The returned array contains a 0 whenever a single doubling is needed, or an
--- odd integer when an addition with a multiple of the base is needed.
---
--- @param bits number[]
--- @param w number Log2 of the radix, must be at least 1.
--- @return number[]
local function wNaf(bits, w)
    -- TODO Find a more elegant way of doing this.
    local wPow = 2 ^ w
    local wPowh = wPow / 2
    local out = {}
    local acc = 0
    local mul = 1
    for i = 1, #bits do
        acc = acc + bits[i] * mul
        mul = mul * 2
        while i == #bits and acc > 0 or mul > wPow do
            if acc % 2 == 0 then
                acc = acc / 2
                mul = mul / 2
                out[#out + 1] = 0
            else
                local rem = acc % wPow
                if rem >= wPowh then rem = rem - wPow end
                acc = acc - rem
                out[#out + 1] = rem
            end
        end
    end
    while out[#out] == 0 do out[#out] = nil end
    return out
end

--- Computes a multiplication table for wNAF form multiplication.
--- @param P EdPoint The base point.
--- @param w number Log2 of the radix, must be at least 1.
--- @return NsPoint[]
local function WNAFTable(P, w)
    local dP = double(P)
    local out = {niels(P)}
    for i = 3, 2 ^ w, 2 do
        out[i] = niels(add(dP, out[i - 2]))
    end
    return out
end

--- Performs a scalar multiplication by the base point G.
--- @param bits number[] The scalar multiplicand little-endian bits.
--- @return EdPoint
local function mulG(bits)
    local sw = signedRadixW(bits, G_W)
    local R = O
    for i = 1, #sw do
        local b = sw[i]
        if b > 0 then
            R = add(R, G_TABLE[i][b])
        elseif b < 0 then
            R = sub(R, G_TABLE[i][-b])
        end
    end
    return R
end

--- Performs a scalar multiplication operation.
--- @param P EdPoint The base point.
--- @param bits number[] The scalar multiplicand little-endian bits.
--- @return EdPoint
local function mul(P, bits)
    local naf = wNaf(bits, 5)
    local tbl = WNAFTable(P, 5)
    local R = O
    for i = #naf, 1, -1 do
        local b = naf[i]
        if b == 0 then
            R = double(R)
        elseif b > 0 then
            R = add(R, tbl[b])
        else
            R = sub(R, tbl[-b])
        end
    end
    return R
end

return {
    double = double,
    add = add,
    sub = sub,
    niels = niels,
    scale = scale,
    encode = encode,
    decode = decode,
    mulG = mulG,
    mul = mul,
}
]=]
F["vendor/ccryptolib/internal/fp.lua"] = [=[
--- Arithmetic on Curve25519's base field.

local packing = require "ccryptolib.internal.packing"

local unpack = unpack or table.unpack
local ufp, fmtfp = packing.compileUnpack("<I3I3I2I3I3I2I3I3I2I3I3I2")

--- @class Fq An element of the field of integers modulo 2²⁵⁵ - 19.

--- @class FpR2: Fq An Fp element with limbs inside twice the standard range.

--- @class FpR1: FpR2 An Fp element with limbs inside the standard range. See
--- the Curve25519 polynomial representation for more info around this.

--- The modular square root of -1.
--- @type FpR1
local I = {
    0958640 * 2 ^ 0,
    0826664 * 2 ^ 22,
    1613251 * 2 ^ 43,
    1041528 * 2 ^ 64,
    0013673 * 2 ^ 85,
    0387171 * 2 ^ 107,
    1824679 * 2 ^ 128,
    0313839 * 2 ^ 149,
    0709440 * 2 ^ 170,
    0122635 * 2 ^ 192,
    0262782 * 2 ^ 213,
    0712905 * 2 ^ 234,
}

--- Converts a Lua number to an element.
--- @param n number A number n in [0..2²²).
--- @return FpR1 out The number as an element.
local function num(n)
    return {n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
end

--- Negates an element.
--- @param a FpR1
--- @return FpR1 out -a.
local function neg(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    return {
        -a00,
        -a01,
        -a02,
        -a03,
        -a04,
        -a05,
        -a06,
        -a07,
        -a08,
        -a09,
        -a10,
        -a11,
    }
end

--- Adds two elements.
--- @param a FpR1
--- @param b FpR1
--- @return FpR2 out a + b.
local function add(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11 = unpack(b)
    return {
        a00 + b00,
        a01 + b01,
        a02 + b02,
        a03 + b03,
        a04 + b04,
        a05 + b05,
        a06 + b06,
        a07 + b07,
        a08 + b08,
        a09 + b09,
        a10 + b10,
        a11 + b11,
    }
end

--- Subtracts an element from another.
--- @param a FpR1
--- @param b FpR1
--- @return FpR2 out a - b.
local function sub(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11 = unpack(b)
    return {
        a00 - b00,
        a01 - b01,
        a02 - b02,
        a03 - b03,
        a04 - b04,
        a05 - b05,
        a06 - b06,
        a07 - b07,
        a08 - b08,
        a09 - b09,
        a10 - b10,
        a11 - b11,
    }
end

--- Carries an element. Also performs a small reduction modulo p.
--- @param a FpR2 The element to carry.
--- @return FpR1 out The same element as a but in a tighter range.
local function carry(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11

    c11 = a11 + 3 * 2 ^ 306 - 3 * 2 ^ 306  a00 = a00 + 19 / 2 ^ 255 * c11

    c00 = a00 + 3 * 2 ^ 73  - 3 * 2 ^ 73   a01 = a01 + c00
    c01 = a01 + 3 * 2 ^ 94  - 3 * 2 ^ 94   a02 = a02 + c01
    c02 = a02 + 3 * 2 ^ 115 - 3 * 2 ^ 115  a03 = a03 + c02
    c03 = a03 + 3 * 2 ^ 136 - 3 * 2 ^ 136  a04 = a04 + c03
    c04 = a04 + 3 * 2 ^ 158 - 3 * 2 ^ 158  a05 = a05 + c04
    c05 = a05 + 3 * 2 ^ 179 - 3 * 2 ^ 179  a06 = a06 + c05
    c06 = a06 + 3 * 2 ^ 200 - 3 * 2 ^ 200  a07 = a07 + c06
    c07 = a07 + 3 * 2 ^ 221 - 3 * 2 ^ 221  a08 = a08 + c07
    c08 = a08 + 3 * 2 ^ 243 - 3 * 2 ^ 243  a09 = a09 + c08
    c09 = a09 + 3 * 2 ^ 264 - 3 * 2 ^ 264  a10 = a10 + c09
    c10 = a10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  a11 = a11 - c11 + c10

    c11 = a11 + 3 * 2 ^ 306 - 3 * 2 ^ 306

    return {
        a00 - c00 + 19 / 2 ^ 255 * c11,
        a01 - c01,
        a02 - c02,
        a03 - c03,
        a04 - c04,
        a05 - c05,
        a06 - c06,
        a07 - c07,
        a08 - c08,
        a09 - c09,
        a10 - c10,
        a11 - c11,
    }
end

--- Returns the canoncal representative of a modp number.
---
--- Some elements can be represented by two different arrays of floats. This
--- returns the canonical element of the represented equivalence class. We
--- define an element as canonical if it's the smallest nonnegative number in
--- its class.
---
--- @param a FpR2
--- @return FpR1 out A canonical element a' ≡ a (mod p).
local function canonicalize(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11

    -- Perform an euclidean reduction.
    -- TODO Range check.
    c00 = a00 % 2 ^ 22   a01 = a00 - c00 + a01
    c01 = a01 % 2 ^ 43   a02 = a01 - c01 + a02
    c02 = a02 % 2 ^ 64   a03 = a02 - c02 + a03
    c03 = a03 % 2 ^ 85   a04 = a03 - c03 + a04
    c04 = a04 % 2 ^ 107  a05 = a04 - c04 + a05
    c05 = a05 % 2 ^ 128  a06 = a05 - c05 + a06
    c06 = a06 % 2 ^ 149  a07 = a06 - c06 + a07
    c07 = a07 % 2 ^ 170  a08 = a07 - c07 + a08
    c08 = a08 % 2 ^ 192  a09 = a08 - c08 + a09
    c09 = a09 % 2 ^ 213  a10 = a09 - c09 + a10
    c10 = a10 % 2 ^ 234  a11 = a10 - c10 + a11
    c11 = a11 % 2 ^ 255  c00 = c00 + 19 / 2 ^ 255 * (a11 - c11)

    -- Canonicalize.
    if      c11 / 2 ^ 234 == 2 ^ 21 - 1
        and c10 / 2 ^ 213 == 2 ^ 21 - 1
        and c09 / 2 ^ 192 == 2 ^ 21 - 1
        and c08 / 2 ^ 170 == 2 ^ 22 - 1
        and c07 / 2 ^ 149 == 2 ^ 21 - 1
        and c06 / 2 ^ 128 == 2 ^ 21 - 1
        and c05 / 2 ^ 107 == 2 ^ 21 - 1
        and c04 / 2 ^ 85  == 2 ^ 22 - 1
        and c03 / 2 ^ 64  == 2 ^ 21 - 1
        and c02 / 2 ^ 43  == 2 ^ 21 - 1
        and c01 / 2 ^ 22  == 2 ^ 21 - 1
        and c00 >= 2 ^ 22 - 19
    then
        return {19 - 2 ^ 22 + c00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
    else
        return {c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11}
    end
end

--- Returns whether two elements are the same.
--- @param a FpR1
--- @param b FpR1
--- @return boolean eq Whether a ≡ b (mod p).
local function eq(a, b)
    local c = canonicalize(sub(a, b))
    for i = 1, 12 do if c[i] ~= 0 then return false end end
    return true
end

--- Multiplies two elements.
--- @param a FpR2
--- @param b FpR2
--- @return FpR1 c An element such that c ≡ a × b (mod p).
local function mul(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11 = unpack(b)
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11

    -- Multiply high half into c00..c11.
    c00 = a11 * b01
        + a10 * b02
        + a09 * b03
        + a08 * b04
        + a07 * b05
        + a06 * b06
        + a05 * b07
        + a04 * b08
        + a03 * b09
        + a02 * b10
        + a01 * b11
    c01 = a11 * b02
        + a10 * b03
        + a09 * b04
        + a08 * b05
        + a07 * b06
        + a06 * b07
        + a05 * b08
        + a04 * b09
        + a03 * b10
        + a02 * b11
    c02 = a11 * b03
        + a10 * b04
        + a09 * b05
        + a08 * b06
        + a07 * b07
        + a06 * b08
        + a05 * b09
        + a04 * b10
        + a03 * b11
    c03 = a11 * b04
        + a10 * b05
        + a09 * b06
        + a08 * b07
        + a07 * b08
        + a06 * b09
        + a05 * b10
        + a04 * b11
    c04 = a11 * b05
        + a10 * b06
        + a09 * b07
        + a08 * b08
        + a07 * b09
        + a06 * b10
        + a05 * b11
    c05 = a11 * b06
        + a10 * b07
        + a09 * b08
        + a08 * b09
        + a07 * b10
        + a06 * b11
    c06 = a11 * b07
        + a10 * b08
        + a09 * b09
        + a08 * b10
        + a07 * b11
    c07 = a11 * b08
        + a10 * b09
        + a09 * b10
        + a08 * b11
    c08 = a11 * b09
        + a10 * b10
        + a09 * b11
    c09 = a11 * b10
        + a10 * b11
    c10 = a11 * b11

    -- Multiply low half with reduction into c00..c11.
    c00 = c00 * (19 / 2 ^ 255)
        + a00 * b00
    c01 = c01 * (19 / 2 ^ 255)
        + a01 * b00
        + a00 * b01
    c02 = c02 * (19 / 2 ^ 255)
        + a02 * b00
        + a01 * b01
        + a00 * b02
    c03 = c03 * (19 / 2 ^ 255)
        + a03 * b00
        + a02 * b01
        + a01 * b02
        + a00 * b03
    c04 = c04 * (19 / 2 ^ 255)
        + a04 * b00
        + a03 * b01
        + a02 * b02
        + a01 * b03
        + a00 * b04
    c05 = c05 * (19 / 2 ^ 255)
        + a05 * b00
        + a04 * b01
        + a03 * b02
        + a02 * b03
        + a01 * b04
        + a00 * b05
    c06 = c06 * (19 / 2 ^ 255)
        + a06 * b00
        + a05 * b01
        + a04 * b02
        + a03 * b03
        + a02 * b04
        + a01 * b05
        + a00 * b06
    c07 = c07 * (19 / 2 ^ 255)
        + a07 * b00
        + a06 * b01
        + a05 * b02
        + a04 * b03
        + a03 * b04
        + a02 * b05
        + a01 * b06
        + a00 * b07
    c08 = c08 * (19 / 2 ^ 255)
        + a08 * b00
        + a07 * b01
        + a06 * b02
        + a05 * b03
        + a04 * b04
        + a03 * b05
        + a02 * b06
        + a01 * b07
        + a00 * b08
    c09 = c09 * (19 / 2 ^ 255)
        + a09 * b00
        + a08 * b01
        + a07 * b02
        + a06 * b03
        + a05 * b04
        + a04 * b05
        + a03 * b06
        + a02 * b07
        + a01 * b08
        + a00 * b09
    c10 = c10 * (19 / 2 ^ 255)
        + a10 * b00
        + a09 * b01
        + a08 * b02
        + a07 * b03
        + a06 * b04
        + a05 * b05
        + a04 * b06
        + a03 * b07
        + a02 * b08
        + a01 * b09
        + a00 * b10
    c11 = a11 * b00
        + a10 * b01
        + a09 * b02
        + a08 * b03
        + a07 * b04
        + a06 * b05
        + a05 * b06
        + a04 * b07
        + a03 * b08
        + a02 * b09
        + a01 * b10
        + a00 * b11

    -- Carry and reduce.
    a10 = c10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  c11 = c11 + a10
    a11 = c11 + 3 * 2 ^ 306 - 3 * 2 ^ 306  c00 = c00 + 19 / 2 ^ 255 * a11

    a00 = c00 + 3 * 2 ^ 73  - 3 * 2 ^ 73   c01 = c01 + a00
    a01 = c01 + 3 * 2 ^ 94  - 3 * 2 ^ 94   c02 = c02 + a01
    a02 = c02 + 3 * 2 ^ 115 - 3 * 2 ^ 115  c03 = c03 + a02
    a03 = c03 + 3 * 2 ^ 136 - 3 * 2 ^ 136  c04 = c04 + a03
    a04 = c04 + 3 * 2 ^ 158 - 3 * 2 ^ 158  c05 = c05 + a04
    a05 = c05 + 3 * 2 ^ 179 - 3 * 2 ^ 179  c06 = c06 + a05
    a06 = c06 + 3 * 2 ^ 200 - 3 * 2 ^ 200  c07 = c07 + a06
    a07 = c07 + 3 * 2 ^ 221 - 3 * 2 ^ 221  c08 = c08 + a07
    a08 = c08 + 3 * 2 ^ 243 - 3 * 2 ^ 243  c09 = c09 + a08
    a09 = c09 + 3 * 2 ^ 264 - 3 * 2 ^ 264  c10 = c10 - a10 + a09
    a10 = c10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  c11 = c11 - a11 + a10

    a11 = c11 + 3 * 2 ^ 306 - 3 * 2 ^ 306

    return {
        c00 - a00 + 19 / 2 ^ 255 * a11,
        c01 - a01,
        c02 - a02,
        c03 - a03,
        c04 - a04,
        c05 - a05,
        c06 - a06,
        c07 - a07,
        c08 - a08,
        c09 - a09,
        c10 - a10,
        c11 - a11,
    }
end

--- Squares an element.
--- @param a FpR2
--- @return FpR1 b An element such that b ≡ a² (mod p).
local function square(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local d00, d01, d02, d03, d04, d05, d06, d07, d08, d09, d10
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11

    -- Compute 2a.
    d00 = a00 + a00
    d01 = a01 + a01
    d02 = a02 + a02
    d03 = a03 + a03
    d04 = a04 + a04
    d05 = a05 + a05
    d06 = a06 + a06
    d07 = a07 + a07
    d08 = a08 + a08
    d09 = a09 + a09
    d10 = a10 + a10

    -- Multiply high half into c00..c11.
    c00 = a11 * d01
        + a10 * d02
        + a09 * d03
        + a08 * d04
        + a07 * d05
        + a06 * a06
    c01 = a11 * d02
        + a10 * d03
        + a09 * d04
        + a08 * d05
        + a07 * d06
    c02 = a11 * d03
        + a10 * d04
        + a09 * d05
        + a08 * d06
        + a07 * a07
    c03 = a11 * d04
        + a10 * d05
        + a09 * d06
        + a08 * d07
    c04 = a11 * d05
        + a10 * d06
        + a09 * d07
        + a08 * a08
    c05 = a11 * d06
        + a10 * d07
        + a09 * d08
    c06 = a11 * d07
        + a10 * d08
        + a09 * a09
    c07 = a11 * d08
        + a10 * d09
    c08 = a11 * d09
        + a10 * a10
    c09 = a11 * d10
    c10 = a11 * a11

    -- Multiply low half with reduction into c00..c11.
    c00 = c00 * (19 / 2 ^ 255)
        + a00 * a00
    c01 = c01 * (19 / 2 ^ 255)
        + a01 * d00
    c02 = c02 * (19 / 2 ^ 255)
        + a02 * d00
        + a01 * a01
    c03 = c03 * (19 / 2 ^ 255)
        + a03 * d00
        + a02 * d01
    c04 = c04 * (19 / 2 ^ 255)
        + a04 * d00
        + a03 * d01
        + a02 * a02
    c05 = c05 * (19 / 2 ^ 255)
        + a05 * d00
        + a04 * d01
        + a03 * d02
    c06 = c06 * (19 / 2 ^ 255)
        + a06 * d00
        + a05 * d01
        + a04 * d02
        + a03 * a03
    c07 = c07 * (19 / 2 ^ 255)
        + a07 * d00
        + a06 * d01
        + a05 * d02
        + a04 * d03
    c08 = c08 * (19 / 2 ^ 255)
        + a08 * d00
        + a07 * d01
        + a06 * d02
        + a05 * d03
        + a04 * a04
    c09 = c09 * (19 / 2 ^ 255)
        + a09 * d00
        + a08 * d01
        + a07 * d02
        + a06 * d03
        + a05 * d04
    c10 = c10 * (19 / 2 ^ 255)
        + a10 * d00
        + a09 * d01
        + a08 * d02
        + a07 * d03
        + a06 * d04
        + a05 * a05
    c11 = a11 * d00
        + a10 * d01
        + a09 * d02
        + a08 * d03
        + a07 * d04
        + a06 * d05

    -- Carry and reduce.
    a10 = c10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  c11 = c11 + a10
    a11 = c11 + 3 * 2 ^ 306 - 3 * 2 ^ 306  c00 = c00 + 19 / 2 ^ 255 * a11

    a00 = c00 + 3 * 2 ^ 73  - 3 * 2 ^ 73   c01 = c01 + a00
    a01 = c01 + 3 * 2 ^ 94  - 3 * 2 ^ 94   c02 = c02 + a01
    a02 = c02 + 3 * 2 ^ 115 - 3 * 2 ^ 115  c03 = c03 + a02
    a03 = c03 + 3 * 2 ^ 136 - 3 * 2 ^ 136  c04 = c04 + a03
    a04 = c04 + 3 * 2 ^ 158 - 3 * 2 ^ 158  c05 = c05 + a04
    a05 = c05 + 3 * 2 ^ 179 - 3 * 2 ^ 179  c06 = c06 + a05
    a06 = c06 + 3 * 2 ^ 200 - 3 * 2 ^ 200  c07 = c07 + a06
    a07 = c07 + 3 * 2 ^ 221 - 3 * 2 ^ 221  c08 = c08 + a07
    a08 = c08 + 3 * 2 ^ 243 - 3 * 2 ^ 243  c09 = c09 + a08
    a09 = c09 + 3 * 2 ^ 264 - 3 * 2 ^ 264  c10 = c10 - a10 + a09
    a10 = c10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  c11 = c11 - a11 + a10

    a11 = c11 + 3 * 2 ^ 306 - 3 * 2 ^ 306

    return {
        c00 - a00 + 19 / 2 ^ 255 * a11,
        c01 - a01,
        c02 - a02,
        c03 - a03,
        c04 - a04,
        c05 - a05,
        c06 - a06,
        c07 - a07,
        c08 - a08,
        c09 - a09,
        c10 - a10,
        c11 - a11,
    }
end

--- Multiplies an element by a number.
--- @param a FpR2
--- @param k number A number in [0..2²²).
--- @return FpR1 c An element such that c ≡ a × k (mod p).
local function kmul(a, k)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11

    -- TODO Range check.
    a00 = a00 * k
    a01 = a01 * k
    a02 = a02 * k
    a03 = a03 * k
    a04 = a04 * k
    a05 = a05 * k
    a06 = a06 * k
    a07 = a07 * k
    a08 = a08 * k
    a09 = a09 * k
    a10 = a10 * k
    a11 = a11 * k

    c11 = a11 + 3 * 2 ^ 306 - 3 * 2 ^ 306  a00 = a00 + 19 / 2 ^ 255 * c11

    c00 = a00 + 3 * 2 ^ 73  - 3 * 2 ^ 73   a01 = a01 + c00
    c01 = a01 + 3 * 2 ^ 94  - 3 * 2 ^ 94   a02 = a02 + c01
    c02 = a02 + 3 * 2 ^ 115 - 3 * 2 ^ 115  a03 = a03 + c02
    c03 = a03 + 3 * 2 ^ 136 - 3 * 2 ^ 136  a04 = a04 + c03
    c04 = a04 + 3 * 2 ^ 158 - 3 * 2 ^ 158  a05 = a05 + c04
    c05 = a05 + 3 * 2 ^ 179 - 3 * 2 ^ 179  a06 = a06 + c05
    c06 = a06 + 3 * 2 ^ 200 - 3 * 2 ^ 200  a07 = a07 + c06
    c07 = a07 + 3 * 2 ^ 221 - 3 * 2 ^ 221  a08 = a08 + c07
    c08 = a08 + 3 * 2 ^ 243 - 3 * 2 ^ 243  a09 = a09 + c08
    c09 = a09 + 3 * 2 ^ 264 - 3 * 2 ^ 264  a10 = a10 + c09
    c10 = a10 + 3 * 2 ^ 285 - 3 * 2 ^ 285  a11 = a11 - c11 + c10

    c11 = a11 + 3 * 2 ^ 306 - 3 * 2 ^ 306

    return {
        a00 - c00 + 19 / 2 ^ 255 * c11,
        a01 - c01,
        a02 - c02,
        a03 - c03,
        a04 - c04,
        a05 - c05,
        a06 - c06,
        a07 - c07,
        a08 - c08,
        a09 - c09,
        a10 - c10,
        a11 - c11
    }
end

--- Squares an element n times.
--- @param a FpR2
--- @param n number The number of times to square a.
--- @return FpR1 c A number c such that c ≡ a ^ 2 ^ n (mod p).
local function nsquare(a, n)
    for _ = 1, n do a = square(a) end
    return a
end

--- Computes the inverse of an element.
---
--- Performance: 11 multiplications and 252 squarings.
---
--- @param a FpR2
--- @return FpR1 c An element such that c ≡ a⁻¹ (mod p), or 0 if c doesn't exist.
local function invert(a)
    local a2 = square(a)
    local a9 = mul(a, nsquare(a2, 2))
    local a11 = mul(a9, a2)

    local x5 = mul(square(a11), a9)
    local x10 = mul(nsquare(x5, 5), x5)
    local x20 = mul(nsquare(x10, 10), x10)
    local x40 = mul(nsquare(x20, 20), x20)
    local x50 = mul(nsquare(x40, 10), x10)
    local x100 = mul(nsquare(x50, 50), x50)
    local x200 = mul(nsquare(x100, 100), x100)
    local x250 = mul(nsquare(x200, 50), x50)

    return mul(nsquare(x250, 5), a11)
end

--- Returns an element x that satisfies vx² = u.
---
--- Note that when v = 0, the returned element can take any value.
---
--- @param u FpR2
--- @param v FpR2
--- @return FpR1? x An element such that vx² ≡ u (mod p), if it exists.
local function sqrtDiv(u, v)
    u = carry(u)

    local v2 = square(v)
    local v3 = mul(v, v2)
    local v6 = square(v3)
    local v7 = mul(v, v6)
    local uv7 = mul(u, v7)

    local x2 = mul(square(uv7), uv7)
    local x4 = mul(nsquare(x2, 2), x2)
    local x8 = mul(nsquare(x4, 4), x4)
    local x16 = mul(nsquare(x8, 8), x8)
    local x18 = mul(nsquare(x16, 2), x2)
    local x32 = mul(nsquare(x16, 16), x16)
    local x50 = mul(nsquare(x32, 18), x18)
    local x100 = mul(nsquare(x50, 50), x50)
    local x200 = mul(nsquare(x100, 100), x100)
    local x250 = mul(nsquare(x200, 50), x50)
    local pr = mul(nsquare(x250, 2), uv7)

    local uv3 = mul(u, v3)
    local b = mul(uv3, pr)
    local b2 = square(b)
    local vb2 = mul(v, b2)

    if not eq(vb2, u) then
        -- Found sqrt(-u/v), multiply by i.
        b = mul(b, I)
        b2 = square(b)
        vb2 = mul(v, b2)
    end

    if eq(vb2, u) then
        return b
    else
        return nil
    end
end

--- @class String32: string A string with length equal to 32 bytes.

--- Encodes an element in little-endian.
--- @param a FpR1
--- @return String32 out The 32-byte canonical encoding of a.
local function encode(a)
    a = canonicalize(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11 = unpack(a)

    local bytes = {}
    local acc = a00

    local function putBytes(n)
        for _ = 1, n do
            local byte = acc % 256
            bytes[#bytes + 1] = byte
            acc = (acc - byte) / 256
        end
    end

    putBytes(2) acc = acc + a01 / 2 ^ 16
    putBytes(3) acc = acc + a02 / 2 ^ 40
    putBytes(3) acc = acc + a03 / 2 ^ 64
    putBytes(2) acc = acc + a04 / 2 ^ 80
    putBytes(3) acc = acc + a05 / 2 ^ 104
    putBytes(3) acc = acc + a06 / 2 ^ 128
    putBytes(2) acc = acc + a07 / 2 ^ 144
    putBytes(3) acc = acc + a08 / 2 ^ 168
    putBytes(3) acc = acc + a09 / 2 ^ 192
    putBytes(2) acc = acc + a10 / 2 ^ 208
    putBytes(3) acc = acc + a11 / 2 ^ 232
    putBytes(3)

    return string.char(unpack(bytes)) --[[@as String32, putBytes sums to 32]]
end

--- Decodes an element in little-endian.
--- @param b String32 A 32-byte string, the most-significant bit is discarded.
--- @return FpR1 out The decoded element. It may not be canonical.
local function decode(b)
    local w00, w01, w02, w03, w04, w05, w06, w07, w08, w09, w10, w11 =
        ufp(fmtfp, b, 1)

    w11 = w11 % 2 ^ 15

    return carry {
        w00,
        w01 * 2 ^ 24,
        w02 * 2 ^ 48,
        w03 * 2 ^ 64,
        w04 * 2 ^ 88,
        w05 * 2 ^ 112,
        w06 * 2 ^ 128,
        w07 * 2 ^ 152,
        w08 * 2 ^ 176,
        w09 * 2 ^ 192,
        w10 * 2 ^ 216,
        w11 * 2 ^ 240,
    }
end

--- Checks if the given element is equal to 0.
--- @param a FpR2
--- @return boolean eqz Whether a ≡ 0 (mod p).
local function eqz(a)
    local c = canonicalize(a)
    local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11 = unpack(c)
    return c00 + c01 + c02 + c03 + c04 + c05 + c06 + c07 + c08 + c09 + c10 + c11
        == 0
end

return {
    num = num,
    neg = neg,
    add = add,
    sub = sub,
    kmul = kmul,
    mul = mul,
    canonicalize = canonicalize,
    square = square,
    carry = carry,
    invert = invert,
    sqrtDiv = sqrtDiv,
    encode = encode,
    decode = decode,
    eqz = eqz,
}
]=]
F["vendor/ccryptolib/internal/fq.lua"] = [=[
--- Arithmetic on Curve25519's scalar field.

local mp = require "ccryptolib.internal.mp"
local util = require "ccryptolib.internal.util"
local packing = require "ccryptolib.internal.packing"

local unpack = unpack or table.unpack
local pfq, fmtfq = packing.compilePack("<I3I3I3I3I3I3I3I3I3I3I2")
local ufq = packing.compileUnpack(fmtfq)
local ufql, fmtfql = packing.compileUnpack("<I3I3I3I3I3I3I3I3I3I3I3")
local ufqh, fmtfqh = packing.compileUnpack("<I3I3I3I3I3I3I3I3I3I3I1")

--- The scalar field's order, q = 2²⁵² + 27742317777372353535851937790883648493.
local Q = {
    16110573,
    06494812,
    14047250,
    10680220,
    14612958,
    00000020,
    00000000,
    00000000,
    00000000,
    00000000,
    00004096,
}

--- The first Montgomery precomputed constant, -q⁻¹ mod 2²⁶⁴.
local T0 = {
    05537307,
    01942290,
    16765621,
    16628356,
    10618610,
    07072433,
    03735459,
    01369940,
    15276086,
    13038191,
    13409718,
}

--- The second Montgomery precomputed constant, 2⁵²⁸ mod q.
local T1 = {
    11711996,
    01747860,
    08326961,
    03814718,
    01859974,
    13327461,
    16105061,
    07590423,
    04050668,
    08138906,
    00000283,
}

local T8 = {
    5110253,
    3039345,
    2503500,
    11779568,
    15416472,
    16766550,
    16777215,
    16777215,
    16777215,
    16777215,
    4095,
}

local ZERO = mp.num(0)

--- Reduces a number modulo q.
--
-- @tparam {number...} a A number a < 2q as 11 limbs in [0..2²⁵).
-- @treturn {number...} a mod q as 11 limbs in [0..2²⁴).
--
local function reduce(a)
    local c = mp.sub(a, Q)
    local out, overflow = mp.carry(c)

    -- Return carry(a) if a < q.
    if overflow < 0 then return (mp.carry(a)) end

    -- c >= q means c - q >= 0.
    -- Since q < 2²⁸⁸, c < 2q means c - q < q < 2²⁸⁸.
    -- c's limbs fit in (-2²⁶..2²⁶), since subtraction adds at most one bit.
    return out -- cc < q implies that the carry number is 0.
end

--- Adds two scalars mod q.
--
-- If the two operands are in Montgomery form, returns the correct result also
-- in Montgomery form, since (2²⁶⁴ × a) + (2²⁶⁴ × b) ≡ 2²⁶⁴ × (a + b) (mod q).
--
-- @tparam {number...} a A number a < q as 11 limbs in [0..2²⁴).
-- @tparam {number...} b A number b < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} a + b mod q as 11 limbs in [0..2²⁴).
--
local function add(a, b)
    return reduce(mp.add(a, b))
end

--- Negates a scalar mod q.
--
-- @tparam {number...} a A number a < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} -a mod q as 11 limbs in [0..2²⁴).
--
local function neg(a)
    return reduce(mp.sub(Q, a))
end

--- Subtracts scalars mod q.
--
-- If the two operands are in Montgomery form, returns the correct result also
-- in Montgomery form, since (2²⁶⁴ × a) - (2²⁶⁴ × b) ≡ 2²⁶⁴ × (a - b) (mod q).
--
-- @tparam {number...} a A number a < q as 11 limbs in [0..2²⁴).
-- @tparam {number...} b A number b < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} a - b mod q as 11 limbs in [0..2²⁴).
--
local function sub(a, b)
    return add(a, neg(b))
end

--- Given two scalars a and b, computes 2⁻²⁶⁴ × a × b mod q.
--
-- @tparam {number...} a A number a as 11 limbs in [0..2²⁴).
-- @tparam {number...} b A number b < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} 2⁻²⁶⁴ × a × b mod q as 11 limbs in [0..2²⁴).
--
local function mul(a, b)
    local t0, t1 = mp.mul(a, b)
    local mq0, mq1 = mp.mul(mp.lmul(t0, T0), Q)
    local _, s1 = mp.dwadd(t0, t1, mq0, mq1)
    return reduce(s1)
end

--- Converts a scalar into Montgomery form.
--
-- @tparam {number...} a A number a as 11 limbs in [0..2²⁴).
-- @treturn {number...} 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
--
local function montgomery(a)
    -- 0 ≤ a < 2²⁶⁴ and 0 ≤ T1 < q.
    return mul(a, T1)
end

--- Converts a scalar from Montgomery form.
--
-- @tparam {number...} a A number a < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} 2⁻²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
--
local function demontgomery(a)
    -- It's REDC all over again except b is 1.
    local mq0, mq1 = mp.mul(mp.lmul(a, T0), Q)
    local _, s1 = mp.dwadd(a, ZERO, mq0, mq1)
    return reduce(s1)
end

--- Encodes a scalar.
--
-- @tparam {number...} a A number 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
-- @treturn string The 32-byte string encoding of a.
--
local function encode(a)
    return pfq(fmtfq, unpack(demontgomery(a)))
end

--- Decodes a scalar.
--
-- @tparam string str A 32-byte string encoding some little-endian number a.
-- @treturn {number...} 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
--
local function decode(str)
    local dec = {ufq(fmtfq, str, 1)} dec[12] = nil
    return montgomery(dec)
end

--- Decodes a scalar from a "wide" string.
--
-- @tparam string str A 64-byte string encoding some little-endian number a.
-- @treturn {number...} 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
--
local function decodeWide(str)
    local low = {ufql(fmtfql, str, 1)} low[12] = nil
    local high = {ufqh(fmtfqh, str, 34)} high[12] = nil
    return add(montgomery(low), montgomery(montgomery(high)))
end

--- Decodes a scalar using the X25519/Ed25519 bit clamping scheme.
--
-- @tparam string str A 32-byte string encoding some little-endian number a.
-- @treturn {number...} 2²⁶⁴ × clamp(a) mod q as 11 limbs in [0..2²⁴).
--
local function decodeClamped(str)
    -- Decode.
    local words = {ufq(fmtfq, str, 1)} words[12] = nil

    -- Clamp.
    words[1] = bit32.band(words[1], 0xfffff8)
    words[11] = bit32.band(words[11], 0x7fff)
    words[11] = bit32.bor(words[11], 0x4000)

    return montgomery(words)
end

--- Divides a scalar by 8.
--
-- @tparam {number...} 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
-- @treturn {number...} 2²⁶⁵ × a ÷ 8 mod q as 11 limbs in [0..2²⁴).
local function eighth(a)
    return mul(a, T8)
end

--- Encodes a scalar for round-trip with dedcodeClamped.
--
-- Only values that are in the decodeClamped range can be re-encoded like this.
--
-- @tparam {number...} a A number 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
-- @treturn string The 32-byte string encoding of 8(a ÷ 8 mod q).
--
local function encodeClamped(a)
    local c1 = demontgomery(eighth(a))
    local c2 = mp.lmul(c1, mp.num(8))
    return pfq(fmtfq, unpack(c2))
end

--- Returns a scalar in binary.
--
-- @tparam {number...} a A number a < q as 11 limbs in [0..2²⁴).
-- @treturn {number...} 2⁻²⁶⁴ × a mod q as 253 bits.
--
local function bits(a)
    local out = util.rebaseLE(demontgomery(a), 2 ^ 24, 2)
    for i = 254, 289 do out[i] = nil end
    return out
end

--- Makes a PRAC ruleset from a pair of scalars.
--
-- For more information see section 3.3 of Speeding up subgroup cryptosystems:
-- Martijn Stam. Speeding up subgroup cryptosystems. PhD thesis, Technische
-- Universiteit Eindhoven, 2003. https://dx.doi.org/10.6100/IR564670.
--
-- @tparam {number...} a A scalar 2²⁶⁴ × a mod q as 11 limbs in [0..2²⁴).
-- @tparam {number...} b A scalar 2²⁶⁴ × b mod q as 11 limbs in [0..2²⁴).
-- @treturn {{number...}, {number...}} The generated ruleset.
--
local function makeRuleset(a, b)
    -- The numbers in raw multiprecision tables.
    ---@type MpSW11L24
    local dt = demontgomery(a) -- (-2²⁴..2²⁴)
    ---@type MpSW11L24
    local et = demontgomery(b) -- (-2²⁴..2²⁴)
    ---@type MpSW11L24
    local ft = mp.carryWeak(mp.sub(dt, et))  -- (-2²⁴..2²⁴)

    -- Residue classes of (d, e) modulo 2.
    local d2 = mp.mod2(dt)
    local e2 = mp.mod2(et)

    -- Residue classes of (d, e) modulo 3.
    local d3 = mp.mod3(dt)
    local e3 = mp.mod3(et)

    -- (e, d - e) in limited-precision floating-point numbers.
    local ef = mp.approx(et)
    local ff = mp.approx(ft)

    -- Lookup table for inversions and halvings modulo 3.
    local lut3 = {[0] = 0, 2, 1}

    local rules = {}
    while true do
        local cmp = mp.cmp(mp.carry(dt), mp.carry(et))
        if cmp == 0 then
            break
        elseif cmp < 0 then
            -- M0. d < e
            rules[#rules + 1] = 0
            -- (d, e) ← (e, d)
            dt, et = et, dt
            d2, e2 = e2, d2
            d3, e3 = e3, d3
            ef = mp.approx(et)
            ft = mp.carry(mp.sub(dt, et))
            ff = -ff
        elseif 4 * ff - ef < -1 and d3 == lut3[e3] then
            -- M1. e < d ≤ 5/4 e, d ≡ -e (mod 3)
            rules[#rules + 1] = 1
            -- (d, e) ← ((2d - e)/3, (2e - d)/3)
            dt = mp.third(mp.carryWeak(mp.add(dt, ft)))
            et = mp.third(mp.carryWeak(mp.sub(et, ft)))
            d2, e2 = e2, d2
            d3, e3 = mp.mod3(dt), mp.mod3(et)
            ef = mp.approx(et)
        elseif 4 * ff - ef < -1 and d2 == e2 and d3 == e3 then
            -- M2. e < d ≤ 5/4 e, d ≡ e (mod 6)
            rules[#rules + 1] = 2
            -- (d, e) ← ((d - e)/2, e)
            dt = mp.half(ft)
            d2 = mp.mod2(dt)
            d3 = lut3[(d3 - e3) % 3]
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif ff - 3 * ef < -1 then
            -- M3. d ≤ 4e
            rules[#rules + 1] = 3
            -- (d, e) ← (d - e, e)
            dt = mp.carryWeak(ft)
            d2 = (d2 - e2) % 2
            d3 = (d3 - e3) % 3
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif d2 == e2 then
            -- M4. d ≡ e (mod 2)
            rules[#rules + 1] = 2
            -- (d, e) ← ((d - e)/2, e)
            dt = mp.half(ft)
            d2 = mp.mod2(dt)
            d3 = lut3[(d3 - e3) % 3]
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif d2 == 0 then
            -- M5. d ≡ 0 (mod 2)
            rules[#rules + 1] = 5
            -- (d, e) ← (d/2, e)
            dt = mp.half(dt)
            d2 = mp.mod2(dt)
            d3 = lut3[d3]
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif d3 == 0 then
            -- M6. d ≡ 0 (mod 3)
            rules[#rules + 1] = 6
            -- (d, e) ← (d/3 - e, e)
            dt = mp.carryWeak(mp.sub(mp.third(dt), et))
            d2 = (d2 - e2) % 2
            d3 = mp.mod3(dt)
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif d3 == lut3[e3] then
            -- M7. d ≡ -e (mod 3)
            rules[#rules + 1] = 7
            -- (d, e) ← ((d - 2e)/3, e)
            dt = mp.third(mp.carryWeak(mp.sub(ft, et)))
            d3 = mp.mod3(dt)
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        elseif d3 == e3 then
            -- M8. d ≡ e (mod 3)
            rules[#rules + 1] = 8
            -- (d, e) ← ((d - e)/3, e)
            dt = mp.third(ft)
            d2 = (d2 - e2) % 2
            d3 = mp.mod3(dt)
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        else
            -- M9. e ≡ 0 (mod 2)
            rules[#rules + 1] = 9
            -- (d, e) ← (d, e/2)
            et = mp.half(et)
            e2 = mp.mod2(et)
            e3 = lut3[e3]
            ef = mp.approx(et)
            ft = mp.carryWeak(mp.sub(dt, et))
            ff = mp.approx(ft)
        end
    end

    local ubits = util.rebaseLE(dt, 2 ^ 24, 2)
    while ubits[#ubits] == 0 do ubits[#ubits] = nil end

    return {ubits, rules}
end

return {
    add = add,
    sub = sub,
    mul = mul,
    encode = encode,
    encodeClamped = encodeClamped,
    decode = decode,
    decodeWide = decodeWide,
    decodeClamped = decodeClamped,
    eighth = eighth,
    bits = bits,
    makeRuleset = makeRuleset,
}
]=]
F["vendor/ccryptolib/internal/hw.lua"] = [=[
local config = require "ccryptolib.config"

local PERIPHERAL_CHECK_INTERVAL = 10

local peripheralName = nil
local peripheralType = nil
local peripheralSeed = nil
local lastCheck = -PERIPHERAL_CHECK_INTERVAL

local function isClassicPeripherals(name)
    local methods = peripheral.getMethods(name)
    if type(methods) ~= "table" then return false end
    local kMethods = {}
    for _, method in ipairs(methods) do
        kMethods[method] = true
    end
    if not kMethods.computeSharedSecret then return false end
    if not kMethods.deriveEcdhPublicKey then return false end
    if not kMethods.derivePublicKey then return false end
    if not kMethods.randomBytes then return false end
    if not kMethods.sha256 then return false end
    if not kMethods.sha512 then return false end
    if not kMethods.sign then return false end
    if not kMethods.verify then return false end
    return true
end

local function findPeripheral()
    if peripheralName ~= nil then return end
    if os.clock() - lastCheck < PERIPHERAL_CHECK_INTERVAL then return end
    lastCheck = os.clock()

    if not peripheral then
        config.usePeripherals(false)
        return
    end

    local found = peripheral.find("cryptographic_accelerator", isClassicPeripherals)
    if found then
        peripheralName = peripheral.getName(found)
        peripheralType = "cryptographic_accelerator"
        local ok, seed = pcall(peripheral.call, peripheralName, "randomBytes", 32)
        if ok then peripheralSeed = seed end
    end
end

local function takeSeed()
    if not config.usePeripherals() then return end
    findPeripheral()
    local out = peripheralSeed
    peripheralSeed = nil
    return out
end

local function checkedCall(method, ...)
    if not config.usePeripherals() then return false end
    findPeripheral()
    if not peripheralName then return false end
    if peripheral.hasType(peripheralName, peripheralType) then
        local ok, out = pcall(peripheral.call, peripheralName, method, ...)
        if not ok or out == nil then return false end
        return true, out
    else
        peripheralName = nil
        peripheralType = nil
        return false
    end
end

local function x25519Exchange(sk, pk)
    return checkedCall("computeSharedSecret", sk, pk)
end

local function x25519PublicKey(sk)
    return checkedCall("deriveEcdhPublicKey", sk)
end

local function ed25519PublicKey(sk)
    return checkedCall("derivePublicKey", sk)
end

local function random(length)
    return checkedCall("randomBytes", length)
end

local function sha256(input)
    return checkedCall("sha256", input, false)
end

local function sha512(input)
    return checkedCall("sha512", input, false)
end

local function ed25519Sign(m, sk)
    return checkedCall("sign", m, sk)
end

local function ed25519Verify(m, s, pk)
    return checkedCall("verify", m, s, pk)
end

return {
    takeSeed = takeSeed,
    x25519Exchange = x25519Exchange,
    x25519PublicKey = x25519PublicKey,
    ed25519PublicKey = ed25519PublicKey,
    random = random,
    sha256 = sha256,
    sha512 = sha512,
    ed25519Sign = ed25519Sign,
    ed25519Verify = ed25519Verify,
}
]=]
F["vendor/ccryptolib/internal/mp.lua"] = [=[
--- Multi-precision arithmetic on 264-bit integers.

local unpack = unpack or table.unpack

--- A little-endian big integer of width 11 in (-2⁵²..2⁵²).
--- @class MpSW11L52

--- A little-endian big integer of width 11 in (-2²⁴, 2²⁴).
--- @class MpSW11L24: MpSW11L52

--- A little-endian big integer of width 11 in [0..2²⁴).
--- @class MpUW11L24: MpSW11L24

--- Carries a number in base 2²⁴ into a signed limb form.
--- @param a MpSW11L52
--- @return MpSW11L24 low The carried low limbs.
--- @return number carry The overflowed carry.
local function carryWeak(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)

    local h00 = a00 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a01 = a01 + h00 * 2 ^ -24
    local h01 = a01 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a02 = a02 + h01 * 2 ^ -24
    local h02 = a02 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a03 = a03 + h02 * 2 ^ -24
    local h03 = a03 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a04 = a04 + h03 * 2 ^ -24
    local h04 = a04 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a05 = a05 + h04 * 2 ^ -24
    local h05 = a05 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a06 = a06 + h05 * 2 ^ -24
    local h06 = a06 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a07 = a07 + h06 * 2 ^ -24
    local h07 = a07 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a08 = a08 + h07 * 2 ^ -24
    local h08 = a08 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a09 = a09 + h08 * 2 ^ -24
    local h09 = a09 + 3 * 2 ^ 75 - 3 * 2 ^ 75 a10 = a10 + h09 * 2 ^ -24
    local h10 = a10 + 3 * 2 ^ 75 - 3 * 2 ^ 75

    return {
        a00 - h00,
        a01 - h01,
        a02 - h02,
        a03 - h03,
        a04 - h04,
        a05 - h05,
        a06 - h06,
        a07 - h07,
        a08 - h08,
        a09 - h09,
        a10 - h10,
    }, h10 * 2 ^ -24
end

--- Carries a number in base 2²⁴.
--- @param a MpSW11L52
--- @return MpUW11L24 low The low 11 limbs of the output.
--- @return number carry The overflow carry.
local function carry(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)

    local l00 = a00 % 2 ^ 24 a01 = a01 + (a00 - l00) * 2 ^ -24
    local l01 = a01 % 2 ^ 24 a02 = a02 + (a01 - l01) * 2 ^ -24
    local l02 = a02 % 2 ^ 24 a03 = a03 + (a02 - l02) * 2 ^ -24
    local l03 = a03 % 2 ^ 24 a04 = a04 + (a03 - l03) * 2 ^ -24
    local l04 = a04 % 2 ^ 24 a05 = a05 + (a04 - l04) * 2 ^ -24
    local l05 = a05 % 2 ^ 24 a06 = a06 + (a05 - l05) * 2 ^ -24
    local l06 = a06 % 2 ^ 24 a07 = a07 + (a06 - l06) * 2 ^ -24
    local l07 = a07 % 2 ^ 24 a08 = a08 + (a07 - l07) * 2 ^ -24
    local l08 = a08 % 2 ^ 24 a09 = a09 + (a08 - l08) * 2 ^ -24
    local l09 = a09 % 2 ^ 24 a10 = a10 + (a09 - l09) * 2 ^ -24
    local l10 = a10 % 2 ^ 24
    local h10 = (a10 - l10) * 2 ^ -24

    return {l00, l01, l02, l03, l04, l05, l06, l07, l08, l09, l10}, h10
end

--- Adds two numbers.
--- @param a MpSW11L24
--- @param b MpSW11L24
--- @return MpSW11L52 c a + b
local function add(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10 = unpack(b)

    return {
        a00 + b00,
        a01 + b01,
        a02 + b02,
        a03 + b03,
        a04 + b04,
        a05 + b05,
        a06 + b06,
        a07 + b07,
        a08 + b08,
        a09 + b09,
        a10 + b10,
    }
end

--- Subtracts a number from another.
--- @param a MpSW11L24
--- @param b MpSW11L24
--- @return MpSW11L52 c a - b
local function sub(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10 = unpack(b)

    return {
        a00 - b00,
        a01 - b01,
        a02 - b02,
        a03 - b03,
        a04 - b04,
        a05 - b05,
        a06 - b06,
        a07 - b07,
        a08 - b08,
        a09 - b09,
        a10 - b10,
    }
end

--- Computes the lower half of a product between two numbers.
--- @param a MpUW11L24
--- @param b MpUW11L24
--- @return MpUW11L24 c a × b (mod 2²⁶⁴)
--- @return number carry ⌊a × b ÷ 2²⁶⁴⌋
local function lmul(a, b)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    local b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10 = unpack(b)

    return carry {
        a00 * b00,
        a01 * b00 + a00 * b01,
        a02 * b00 + a01 * b01 + a00 * b02,
        a03 * b00 + a02 * b01 + a01 * b02 + a00 * b03,
        a04 * b00 + a03 * b01 + a02 * b02 + a01 * b03 + a00 * b04,
        a05 * b00 + a04 * b01 + a03 * b02 + a02 * b03 + a01 * b04 + a00 * b05,
        a06 * b00 + a05 * b01 + a04 * b02 + a03 * b03 + a02 * b04 + a01 * b05 + a00 * b06,
        a07 * b00 + a06 * b01 + a05 * b02 + a04 * b03 + a03 * b04 + a02 * b05 + a01 * b06 + a00 * b07,
        a08 * b00 + a07 * b01 + a06 * b02 + a05 * b03 + a04 * b04 + a03 * b05 + a02 * b06 + a01 * b07 + a00 * b08,
        a09 * b00 + a08 * b01 + a07 * b02 + a06 * b03 + a05 * b04 + a04 * b05 + a03 * b06 + a02 * b07 + a01 * b08 + a00 * b09,
        a10 * b00 + a09 * b01 + a08 * b02 + a07 * b03 + a06 * b04 + a05 * b05 + a04 * b06 + a03 * b07 + a02 * b08 + a01 * b09 + a00 * b10,
    }
end

--- Computes the a product between two numbers.
--- @param a MpUW11L24
--- @param b MpUW11L24
--- @return MpUW11L24 low The low 11 limbs of a × b.
--- @return MpUW11L24 high The high 11 limbs of a × b.
local function mul(a, b)
    local low, of = lmul(a, b)

    local _, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    local _, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10 = unpack(b)

    -- The carry is always 0.
    return low, (carry {
        of + a10 * b01 + a09 * b02 + a08 * b03 + a07 * b04 + a06 * b05 + a05 * b06 + a04 * b07 + a03 * b08 + a02 * b09 + a01 * b10,
        a10 * b02 + a09 * b03 + a08 * b04 + a07 * b05 + a06 * b06 + a05 * b07 + a04 * b08 + a03 * b09 + a02 * b10,
        a10 * b03 + a09 * b04 + a08 * b05 + a07 * b06 + a06 * b07 + a05 * b08 + a04 * b09 + a03 * b10,
        a10 * b04 + a09 * b05 + a08 * b06 + a07 * b07 + a06 * b08 + a05 * b09 + a04 * b10,
        a10 * b05 + a09 * b06 + a08 * b07 + a07 * b08 + a06 * b09 + a05 * b10,
        a10 * b06 + a09 * b07 + a08 * b08 + a07 * b09 + a06 * b10,
        a10 * b07 + a09 * b08 + a08 * b09 + a07 * b10,
        a10 * b08 + a09 * b09 + a08 * b10,
        a10 * b09 + a09 * b10,
        a10 * b10,
        0
    })
end

--- Computes a double-width sum of two numbers.
--- @param a0 MpUW11L24 The low 11 limbs of a.
--- @param a1 MpUW11L24 The high 11 limbs of a.
--- @param b0 MpUW11L24 The low 11 limbs of b.
--- @param b1 MpUW11L24 The high 11 limbs of b.
--- @return MpUW11L24 c0 The low 11 limbs of a + b.
--- @return MpUW11L24 c1 The high 11 limbs of a + b.
--- @return number The carry.
local function dwadd(a0, a1, b0, b1)
    local low, c = carry(add(a0, b0))
    local high = add(a1, b1)
    high[1] = high[1] + c
    return low, carry(high)
end

--- Computes half of a number.
--- @param a MpSW11L24 The number to halve, must be even.
--- @return MpSW11L24 c a ÷ 2
local function half(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)

    return (carryWeak {
        a00 * 0.5 + a01 * 2 ^ 23,
        a02 * 2 ^ 23,
        a03 * 2 ^ 23,
        a04 * 2 ^ 23,
        a05 * 2 ^ 23,
        a06 * 2 ^ 23,
        a07 * 2 ^ 23,
        a08 * 2 ^ 23,
        a09 * 2 ^ 23,
        a10 * 2 ^ 23,
        0,
    })
end

--- Computes a third of a number.
--- @param a MpSW11L24 The number to divide, must be a multiple of 3.
--- @return MpSW11L24 c a ÷ 3
local function third(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)

    local d00 = a00 * 0xaaaaaa
    local d01 = a01 * 0xaaaaaa + d00
    local d02 = a02 * 0xaaaaaa + d01
    local d03 = a03 * 0xaaaaaa + d02
    local d04 = a04 * 0xaaaaaa + d03
    local d05 = a05 * 0xaaaaaa + d04
    local d06 = a06 * 0xaaaaaa + d05
    local d07 = a07 * 0xaaaaaa + d06
    local d08 = a08 * 0xaaaaaa + d07
    local d09 = a09 * 0xaaaaaa + d08
    local d10 = a10 * 0xaaaaaa + d09

    -- We compute the modular division mod 2²⁶⁴. The carry isn't 0 but it isn't
    -- part of a ÷ 3 either.
    return (carryWeak {
        a00 + d00,
        a01 + d01,
        a02 + d02,
        a03 + d03,
        a04 + d04,
        a05 + d05,
        a06 + d06,
        a07 + d07,
        a08 + d08,
        a09 + d09,
        a10 + d10,
    })
end

--- Computes a number modulo 2.
--- @param a MpSW11L24
--- @return number c a mod 2.
local function mod2(a)
    return a[1] % 2
end

--- Computes a number modulo 3.
--- @param a MpSW11L24
--- @return number c a mod 3.
local function mod3(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    return (a00 + a01 + a02 + a03 + a04 + a05 + a06 + a07 + a08 + a09 + a10) % 3
end

--- Computes a double representing the most-significant bits of a number.
--- @param a MpSW11L52
--- @return number c A floating-point approximation for the value of a.
local function approx(a)
    local a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10 = unpack(a)
    return a00
        + a01 * 2 ^ 24
        + a02 * 2 ^ 48
        + a03 * 2 ^ 72
        + a04 * 2 ^ 96
        + a05 * 2 ^ 120
        + a06 * 2 ^ 144
        + a07 * 2 ^ 168
        + a08 * 2 ^ 192
        + a09 * 2 ^ 216
        + a10 * 2 ^ 240
end

--- @param a MpUW11L24
--- @param b MpUW11L24
--- @return number c A number that compares to 0 the same as a compares to b.
local function cmp(a, b)
    return a[11] < b[11] and -1
        or a[11] > b[11] and 1
        or a[10] < b[10] and -1
        or a[10] > b[10] and 1
        or a[9] < b[9] and -1
        or a[9] > b[9] and 1
        or a[8] < b[8] and -1
        or a[8] > b[8] and 1
        or a[7] < b[7] and -1
        or a[7] > b[7] and 1
        or a[6] < b[6] and -1
        or a[6] > b[6] and 1
        or a[5] < b[5] and -1
        or a[5] > b[5] and 1
        or a[4] < b[4] and -1
        or a[4] > b[4] and 1
        or a[3] < b[3] and -1
        or a[3] > b[3] and 1
        or a[2] < b[2] and -1
        or a[2] > b[2] and 1
        or a[1] < b[1] and -1
        or a[1] > b[1] and 1
        or 0
end

local function num(a)
    return {a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
end

return {
    carry = carry,
    carryWeak = carryWeak,
    add = add,
    sub = sub,
    dwadd = dwadd,
    lmul = lmul,
    mul = mul,
    half = half,
    third = third,
    mod2 = mod2,
    mod3 = mod3,
    approx = approx,
    cmp = cmp,
    num = num,
}
]=]
F["vendor/ccryptolib/internal/packing.lua"] = [=[
--- High-performance binary packing of integers.
---
--- Remark (and warning):
--- For performance reasons, **the generated functions do not check types,
--- lengths, nor ranges**. You must ensure that the passed arguments are
--- well-formed and respect the format string yourself.

local fmt = string.format

local function mkPack(words, BE)
    local out = "local C=string.char return function(_,"
    local nb = 0
    for i = 1, #words do
        out = out .. fmt("n%d,", i)
        nb = nb + words[i]
    end
    out = out:sub(1, -2) .. ")local "
    for i = 1, nb do
        out = out .. fmt("b%d,", i)
    end
    out = out:sub(1, -2) .. " "
    local bi = 1
    for i = 1, #words do
        for _ = 1, words[i] - 1 do
            out = out .. fmt("b%d=n%d%%2^8 n%d=(n%d-b%d)*2^-8 ", bi, i, i, i, bi)
            bi = bi + 1
        end
        bi = bi + 1
    end
    out = out .. "return C("
    bi = 1
    if not BE then
        for i = 1, #words do
            for _ = 1, words[i] - 1 do
                out = out .. fmt("b%d,", bi)
                bi = bi + 1
            end
            out = out .. fmt("n%d%%2^8,", i)
            bi = bi + 1
        end
    else
        for i = 1, #words do
            out = out .. fmt("n%d%%2^8,", i)
            bi = bi + words[i] - 2
            for _ = 1, words[i] - 1 do
                out = out .. fmt("b%d,", bi)
                bi = bi - 1
            end
            bi = bi + words[i] + 1
        end
    end
    out = out:sub(1, -2) .. ")end"
    return load(out)()
end

local function mkUnpack(words, BE)
    local out = "local B=string.byte return function(_,s,i)local "
    local bi = 1
    if not BE then
        for i = 1, #words do
            for _ = 1, words[i] do
                out = out .. fmt("b%d,", bi)
                bi = bi + 1
            end
        end
    else
        for i = 1, #words do
            bi = bi + words[i] - 1
            for _ = 1, words[i] do
                out = out .. fmt("b%d,", bi)
                bi = bi - 1
            end
            bi = bi + words[i] + 1
        end
    end
    out = out:sub(1, -2) .. fmt("=B(s,i,i+%d)return ", bi - 2)
    bi = 1
    for i = 1, #words do
        out = out .. fmt("b%d", bi)
        bi = bi + 1
        for j = 2, words[i] do
            out = out .. fmt("+b%d*2^%d", bi, 8 * j - 8)
            bi = bi + 1
        end
        out = out .. ","
    end
    out = out .. fmt("i+%d end", bi - 1)
    return load(out)()
end

-- Check whether string.pack is implemented in a high-speed language.
if not string.pack or pcall(string.dump, string.pack) then
    local function compile(fmt, fn)
        local e = assert(fmt:match("^([><])I[I%d]+$"), "invalid format string")
        local w = {}
        for i in fmt:gmatch("I([%d]+)") do
            local n = tonumber(i) or 4
            assert(n > 0 and n <= 16, "integral size out of limits")
            w[#w + 1] = n
        end
        return fn(w, e == ">")
    end

    local packCache = {}
    local unpackCache = {}

    -- I CAN'T EVEN WITH THIS EXTENSION, WHY CAN'T IT HANDLE MORE THAN A SINGLE
    -- LINE OF RETURN DESCRIPTION? LOOK AT IT!!! THE COMMENT GOES OVER THERE ------------------------------------------------------------------> look! ↓ ↓ ↓

    --- (string.pack is nil) Compiles a binary packing function.
    ---
    --- Errors if the format string is invalid or has an invalid integral size,
    --- or if the compiled function turns out too large.
    ---
    --- @param fmt string A string matched by `^([><])I[I%d]+$`.
    --- @return fun(_ignored: any, ...: any): string pack A function that behaves like an unsafe version of `string.pack` for the given format string.
    --- @return string fmt
    local function compilePack(fmt)
        if not packCache[fmt] then
            packCache[fmt] = compile(fmt, mkPack)
        end
        return packCache[fmt], fmt
    end

    --- (string.pack is nil) Compiles a binary unpacking function.
    ---
    --- Errors if the format string is invalid or has an invalid integral size,
    --- or if the compiled function turns out too large.
    ---
    --- @param fmt string A string matched by `^([><])I[I%d]+$`.
    --- @return fun(_ignored: any, str: string, pos: number) unpack A function that behaves like an unsafe version of `string.unpack` for the given format string. Note that the third argument isn't optional.
    --- @return string fmt
    local function compileUnpack(fmt)
        if not unpackCache[fmt] then
            unpackCache[fmt] = compile(fmt, mkUnpack)
        end
        return unpackCache[fmt], fmt
    end

    return {
        compilePack = compilePack,
        compileUnpack = compileUnpack,
    }
else
    --- (string.pack isn't nil) It's string.pack! It returns string.pack!
    --- @param fmt string
    --- @return fun(fmt: string, ...: any): string pack string.pack!
    --- @return string fmt
    local function compilePack(fmt) return string.pack, fmt end

    --- (string.pack isn't nil) It's string.unpack! It returns string.unpack!
    --- @param fmt string
    --- @return fun(fmt: string, str: string, pos: number) unpack string.unpack!
    --- @return string fmt
    local function compileUnpack(fmt) return string.unpack, fmt end

    return {
        compilePack = compilePack,
        compileUnpack = compileUnpack,
    }
end
]=]
F["vendor/ccryptolib/internal/sha512.lua"] = [=[
--- The SHA512 cryptographic hash function.

local expect = require "cc.expect".expect
local packing = require "ccryptolib.internal.packing"
local hw = require "ccryptolib.internal.hw"

local shl = bit32.lshift
local shr = bit32.rshift
local bxor = bit32.bxor
local bnot = bit32.bnot
local band = bit32.band
local p1x16, fmt1x16 = packing.compilePack(">I16")
local p16x4, fmt16x4 = packing.compilePack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4")
local u32x4, fmt32x4 = packing.compileUnpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4")

local function carry64(a1, a0)
    local r0 = a0 % 2 ^ 32
    a1 = a1 + (a0 - r0) / 2 ^ 32
    return a1 % 2 ^ 32, r0
end

local K = {
    0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f,
    0xe9b5dba5, 0x8189dbbc, 0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019,
    0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118, 0xd807aa98, 0xa3030242,
    0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
    0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235,
    0xc19bf174, 0xcf692694, 0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3,
    0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65, 0x2de92c6f, 0x592b0275,
    0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
    0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f,
    0xbf597fc7, 0xbeef0ee4, 0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725,
    0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70, 0x27b70a85, 0x46d22ffc,
    0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
    0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6,
    0x92722c85, 0x1482353b, 0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001,
    0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30, 0xd192e819, 0xd6ef5218,
    0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
    0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99,
    0x34b0bcb5, 0xe19b48a8, 0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb,
    0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3, 0x748f82ee, 0x5defb2fc,
    0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
    0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915,
    0xc67178f2, 0xe372532b, 0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207,
    0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178, 0x06f067aa, 0x72176fba,
    0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
    0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc,
    0x431d67c4, 0x9c100d4c, 0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a,
    0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

--- Hashes data bytes using SHA512.
--- @param data string The input data.
--- @return string hash The 64-byte hash value.
local function digest(data)
    expect(1, data, "string")
    local ok, out = hw.sha512(data)
    if ok then return out end

    -- Pad input.
    local bitlen = #data * 8
    local padlen = -(#data + 17) % 128
    data = data .. "\x80" .. ("\0"):rep(padlen) .. p1x16(fmt1x16, bitlen)

    -- Initialize state.
    local h01, h00 = 0x6a09e667, 0xf3bcc908
    local h11, h10 = 0xbb67ae85, 0x84caa73b
    local h21, h20 = 0x3c6ef372, 0xfe94f82b
    local h31, h30 = 0xa54ff53a, 0x5f1d36f1
    local h41, h40 = 0x510e527f, 0xade682d1
    local h51, h50 = 0x9b05688c, 0x2b3e6c1f
    local h61, h60 = 0x1f83d9ab, 0xfb41bd6b
    local h71, h70 = 0x5be0cd19, 0x137e2179

    -- Digest.
    for i = 1, #data, 128 do
        local w = {u32x4(fmt32x4, data, i)}

        -- Message schedule.
        for j = 33, 160, 2 do
            local wf1, wf0 = w[j - 30], w[j - 29]
            local t1 = shr(wf1, 1) + shl(wf0, 31)
            local t0 = shr(wf0, 1) + shl(wf1, 31)
            local u1 = shr(wf1, 8) + shl(wf0, 24)
            local u0 = shr(wf0, 8) + shl(wf1, 24)
            local v1 = shr(wf1, 7)
            local v0 = shr(wf0, 7) + shl(wf1, 25)

            local w21, w20 = w[j - 4], w[j - 3]
            local w1 = shr(w21, 19) + shl(w20, 13)
            local w0 = shr(w20, 19) + shl(w21, 13)
            local x0 = shr(w21, 29) + shl(w20, 3)
            local x1 = shr(w20, 29) + shl(w21, 3)
            local y1 = shr(w21, 6)
            local y0 = shr(w20, 6) + shl(w21, 26)

            local r1, r0 =
                w[j - 32] + bxor(t1, u1, v1) + w[j - 14] + bxor(w1, x1, y1),
                w[j - 31] + bxor(t0, u0, v0) + w[j - 13] + bxor(w0, x0, y0)

            w[j], w[j + 1] = carry64(r1, r0)
        end

        -- Block function.
        local a1, a0 = h01, h00
        local b1, b0 = h11, h10
        local c1, c0 = h21, h20
        local d1, d0 = h31, h30
        local e1, e0 = h41, h40
        local f1, f0 = h51, h50
        local g1, g0 = h61, h60
        local h1, h0 = h71, h70
        for j = 1, 160, 2 do
            local t1 = shr(e1, 14) + shl(e0, 18)
            local t0 = shr(e0, 14) + shl(e1, 18)
            local u1 = shr(e1, 18) + shl(e0, 14)
            local u0 = shr(e0, 18) + shl(e1, 14)
            local v0 = shr(e1, 9) + shl(e0, 23)
            local v1 = shr(e0, 9) + shl(e1, 23)
            local s11 = bxor(t1, u1, v1)
            local s10 = bxor(t0, u0, v0)

            local ch1 = bxor(band(e1, f1), band(bnot(e1), g1))
            local ch0 = bxor(band(e0, f0), band(bnot(e0), g0))

            local temp11 = h1 + s11 + ch1 + K[j] + w[j]
            local temp10 = h0 + s10 + ch0 + K[j + 1] + w[j + 1]

            local w1 = shr(a1, 28) + shl(a0, 4)
            local w0 = shr(a0, 28) + shl(a1, 4)
            local x0 = shr(a1, 2) + shl(a0, 30)
            local x1 = shr(a0, 2) + shl(a1, 30)
            local y0 = shr(a1, 7) + shl(a0, 25)
            local y1 = shr(a0, 7) + shl(a1, 25)
            local s01 = bxor(w1, x1, y1)
            local s00 = bxor(w0, x0, y0)

            local maj1 = bxor(band(a1, b1), band(a1, c1), band(b1, c1))
            local maj0 = bxor(band(a0, b0), band(a0, c0), band(b0, c0))

            local temp21 = s01 + maj1
            local temp20 = s00 + maj0

            h1 = g1  h0 = g0
            g1 = f1  g0 = f0
            f1 = e1  f0 = e0
            e1, e0 = carry64(d1 + temp11, d0 + temp10)
            d1 = c1  d0 = c0
            c1 = b1  c0 = b0
            b1 = a1  b0 = a0
            a1, a0 = carry64(temp11 + temp21, temp10 + temp20)
        end

        h01, h00 = carry64(h01 + a1, h00 + a0)
        h11, h10 = carry64(h11 + b1, h10 + b0)
        h21, h20 = carry64(h21 + c1, h20 + c0)
        h31, h30 = carry64(h31 + d1, h30 + d0)
        h41, h40 = carry64(h41 + e1, h40 + e0)
        h51, h50 = carry64(h51 + f1, h50 + f0)
        h61, h60 = carry64(h61 + g1, h60 + g0)
        h71, h70 = carry64(h71 + h1, h70 + h0)
    end

    return p16x4(fmt16x4,
        h01, h00, h11, h10, h21, h20, h31, h30,
        h41, h40, h51, h50, h61, h60, h71, h70
    )
end

return {
    digest = digest,
}
]=]
F["vendor/ccryptolib/internal/util.lua"] = [=[
local function lassert(val, err, level)
    if not val then error(err, level + 1) end
    return val
end

--- Converts a little-endian array from one power-of-two base to another.
--- @param a number[] The array to convert, in little-endian.
--- @param base1 number The base to convert from. Must be a power of 2.
--- @param base2 number The base to convert to. Must be a power of 2.
--- @return number[]
local function rebaseLE(a, base1, base2) -- TODO Write contract properly.
    local out = {}
    local outlen = 1
    local acc = 0
    local mul = 1
    for i = 1, #a do
        acc = acc + a[i] * mul
        mul = mul * base1
        while mul >= base2 do
            local rem = acc % base2
            acc = (acc - rem) / base2
            mul = mul / base2
            out[outlen] = rem
            outlen = outlen + 1
        end
    end
    if mul > 0 then
        out[outlen] = acc
    end
    return out
end

--- Decodes bits with X25519/Ed25519 exponent clamping.
--- @param str string The 32-byte encoded exponent.
--- @return number[] bits The decoded clamped bits.
local function bits(str)
    -- Decode.
    local bytes = {str:byte(1, 32)}
    local out = {}
    for i = 1, 32 do
        local byte = bytes[i]
        for j = -7, 0 do
            local bit = byte % 2
            out[8 * i + j] = bit
            byte = (byte - bit) / 2
        end
    end

    -- Clamp.
    out[1] = 0
    out[2] = 0
    out[3] = 0
    out[255] = 1
    out[256] = 0

    return out
end

--- Decodes bits with X25519/Ed25519 exponent clamping and division by 8.
--- @param str string The 32-byte encoded exponent.
--- @return number[] bits The decoded clamped bits, divided by 8.
local function bits8(str)
    return {unpack(bits(str), 4)}
end

return {
    lassert = lassert,
    rebaseLE = rebaseLE,
    bits = bits,
    bits8 = bits8,
}
]=]
F["vendor/ccryptolib/poly1305.lua"] = [=[
--- The Poly1305 one-time authenticator.

local expect  = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local packing = require "ccryptolib.internal.packing"

local u4x4, fmt4x4 = packing.compileUnpack("<I4I4I4I4")
local p4x4 = packing.compilePack(fmt4x4)

--- Computes a Poly1305 message authentication code.
--- @param key string A 32-byte single-use random key.
--- @param message string The message to authenticate.
--- @return string tag The 16-byte authentication tag.
local function mac(key, message)
    expect(1, key, "string")
    lassert(#key == 32, "key length must be 32", 2)
    expect(2, message, "string")

    -- Pad message.
    local pbplen = #message - 15
    if #message % 16 ~= 0 or #message == 0 then
        message = message .. "\1"
        message = message .. ("\0"):rep(-#message % 16)
    end

    -- Decode r.
    local R0, R1, R2, R3 = u4x4(fmt4x4, key, 1)

    -- Clamp and shift.
    R0 = R0 % 2 ^ 28
    R1 = (R1 - R1 % 4) % 2 ^ 28 * 2 ^ 32
    R2 = (R2 - R2 % 4) % 2 ^ 28 * 2 ^ 64
    R3 = (R3 - R3 % 4) % 2 ^ 28 * 2 ^ 96

    -- Split.
    local r0 = R0 % 2 ^ 18   local r1 = R0 - r0
    local r2 = R1 % 2 ^ 50   local r3 = R1 - r2
    local r4 = R2 % 2 ^ 82   local r5 = R2 - r4
    local r6 = R3 % 2 ^ 112  local r7 = R3 - r6

    -- Generate scaled key.
    local S1 = 5 / 2 ^ 130 * R1
    local S2 = 5 / 2 ^ 130 * R2
    local S3 = 5 / 2 ^ 130 * R3

    -- Split.
    local s2 = S1 % 2 ^ -80  local s3 = S1 - s2
    local s4 = S2 % 2 ^ -48  local s5 = S2 - s4
    local s6 = S3 % 2 ^ -16  local s7 = S3 - s6

    local h0, h1, h2, h3, h4, h5, h6, h7 = 0, 0, 0, 0, 0, 0, 0, 0

    for i = 1, #message, 16 do
        -- Decode message block.
        local m0, m1, m2, m3 = u4x4(fmt4x4, message, i)

        -- Shift message and add.
        local x0 = h0 + h1 + m0
        local x2 = h2 + h3 + m1 * 2 ^ 32
        local x4 = h4 + h5 + m2 * 2 ^ 64
        local x6 = h6 + h7 + m3 * 2 ^ 96

        -- Apply per-block padding when applicable.
        if i <= pbplen then x6 = x6 + 2 ^ 128 end

        -- Multiply
        h0 = x0 * r0 + x2 * s6 + x4 * s4 + x6 * s2
        h1 = x0 * r1 + x2 * s7 + x4 * s5 + x6 * s3
        h2 = x0 * r2 + x2 * r0 + x4 * s6 + x6 * s4
        h3 = x0 * r3 + x2 * r1 + x4 * s7 + x6 * s5
        h4 = x0 * r4 + x2 * r2 + x4 * r0 + x6 * s6
        h5 = x0 * r5 + x2 * r3 + x4 * r1 + x6 * s7
        h6 = x0 * r6 + x2 * r4 + x4 * r2 + x6 * r0
        h7 = x0 * r7 + x2 * r5 + x4 * r3 + x6 * r1

        -- Carry.
        local y0 = h0 + 3 * 2 ^ 69  - 3 * 2 ^ 69   h0 = h0 - y0  h1 = h1 + y0
        local y1 = h1 + 3 * 2 ^ 83  - 3 * 2 ^ 83   h1 = h1 - y1  h2 = h2 + y1
        local y2 = h2 + 3 * 2 ^ 101 - 3 * 2 ^ 101  h2 = h2 - y2  h3 = h3 + y2
        local y3 = h3 + 3 * 2 ^ 115 - 3 * 2 ^ 115  h3 = h3 - y3  h4 = h4 + y3
        local y4 = h4 + 3 * 2 ^ 133 - 3 * 2 ^ 133  h4 = h4 - y4  h5 = h5 + y4
        local y5 = h5 + 3 * 2 ^ 147 - 3 * 2 ^ 147  h5 = h5 - y5  h6 = h6 + y5
        local y6 = h6 + 3 * 2 ^ 163 - 3 * 2 ^ 163  h6 = h6 - y6  h7 = h7 + y6
        local y7 = h7 + 3 * 2 ^ 181 - 3 * 2 ^ 181  h7 = h7 - y7

        -- Reduce carry overflow into first limb.
        h0 = h0 + 5 / 2 ^ 130 * y7
    end

    -- Carry canonically.
    local c0 = h0 % 2 ^ 16   h1 = h0 - c0 + h1
    local c1 = h1 % 2 ^ 32   h2 = h1 - c1 + h2
    local c2 = h2 % 2 ^ 48   h3 = h2 - c2 + h3
    local c3 = h3 % 2 ^ 64   h4 = h3 - c3 + h4
    local c4 = h4 % 2 ^ 80   h5 = h4 - c4 + h5
    local c5 = h5 % 2 ^ 96   h6 = h5 - c5 + h6
    local c6 = h6 % 2 ^ 112  h7 = h6 - c6 + h7
    local c7 = h7 % 2 ^ 130

    -- Reduce carry overflow.
    h0 = c0 + 5 / 2 ^ 130 * (h7 - c7)
    c0 = h0 % 2 ^ 16
    c1 = h0 - c0 + c1

    -- Canonicalize.
    if      c7 == 0x3ffff * 2 ^ 112
        and c6 == 0xffff * 2 ^ 96
        and c5 == 0xffff * 2 ^ 80
        and c4 == 0xffff * 2 ^ 64
        and c3 == 0xffff * 2 ^ 48
        and c2 == 0xffff * 2 ^ 32
        and c1 == 0xffff * 2 ^ 16
        and c0 >= 0xfffb
    then
        c7, c6, c5, c4, c3, c2, c1, c0 = 0, 0, 0, 0, 0, 0, 0, c0 - 0xfffb
    end

    -- Decode s.
    local s0, s1, s2, s3 = u4x4(fmt4x4, key, 17)

    -- Add.
    local t0 =           s0          + c0 + c1  local u0 = t0 % 2 ^ 32
    local t1 = t0 - u0 + s1 * 2 ^ 32 + c2 + c3  local u1 = t1 % 2 ^ 64
    local t2 = t1 - u1 + s2 * 2 ^ 64 + c4 + c5  local u2 = t2 % 2 ^ 96
    local t3 = t2 - u2 + s3 * 2 ^ 96 + c6 + c7  local u3 = t3 % 2 ^ 128

    -- Encode.
    return p4x4(fmt4x4, u0, u1 / 2 ^ 32, u2 / 2 ^ 64, u3 / 2 ^ 96)
end

return {
    mac = mac,
}
]=]
F["vendor/ccryptolib/random.lua"] = [=[
local expect = require "cc.expect".expect
local hw = require "ccryptolib.internal.hw"
local blake3 = require "ccryptolib.blake3"
local chacha20 = require "ccryptolib.chacha20"
local util = require "ccryptolib.internal.util"

local lassert = util.lassert

-- Extract local context.
local ctx = {
    "ccryptolib 2023-04-11T19:43Z random.lua initialization context",
    os.epoch("utc"),
    os.day(),
    os.time(),
    math.random(0, 2 ^ 24 - 1),
    math.random(0, 2 ^ 24 - 1),
    tostring({}),
    tostring({}),
}

local state = blake3.digest(table.concat(ctx, "|"))
local initialized = false
local hwMixed = false

--- Mixes random bytes taken by the last compatible peripheral we interacted
--- with, if any.
---
--- takeSeed resets to nil once called, so this function only does work when a
--- peripheral is (re-)attached.
local function mixHwSeed()
    local seed = hw.takeSeed()
    if not seed then return end
    state = blake3.digestKeyed(state, seed)
    hwMixed = true
end

--- Mixes entropy into the generator, and marks it as initialized.
--- @param seed string The seed data.
local function init(seed)
    expect(1, seed, "string")
    mixHwSeed()
    state = blake3.digestKeyed(state, seed)
    initialized = true
end

--- Returns whether the generator has been initialized or not.
--- @return boolean
local function isInit()
    return initialized
end

--- Initializes the generator using VM instruction timing noise.
---
--- This function counts how many instructions the VM can execute within a single
--- millisecond, and mixes the lower bits of these values into the generator state.
--- The current implementation collects data for 512 ms and takes the lower 8 bits from
--- each count.
---
--- Compared to fetching entropy from a trusted web source, this approach is riskier but
--- more convenient. The factors that influence instruction timing suggest that this
--- seed is unpredictable for other players, but this assumption might turn out to be
--- untrue.
local function initWithTiming()
    mixHwSeed()
    assert(os.epoch("utc") ~= 0)

    local f = assert(load("local e=os.epoch return{" .. ("e'utc',"):rep(256) .. "}"))

    do -- Warmup.
        local t = f()
        while t[256] - t[1] > 1 do t = f() end
    end

    -- Fill up the buffer.
    local buf = {}
    for i = 1, 512 do
        local t = f()
        while t[256] == t[1] do t = f() end
        for j = 1, 256 do
            if t[j] ~= t[1] then
                buf[i] = j - 1
                break
            end
        end
    end

    -- Perform a histogram check to catch faulty os.epoch implementations.
    local hist = {}
    for i = 0, 255 do hist[i] = 0 end
    for i = 1, #buf do hist[buf[i]] = hist[buf[i]] + 1 end
    for i = 0, 255 do assert(hist[i] < 20) end

    init(string.char(table.unpack(buf)))
end

--- Initializes the generator with the best available source.
---
--- If no other sources are found, this function will resort to `initWithTiming`
--- as entropy source. See its documentation for security caveats.
local function initAuto()
    mixHwSeed()
    if not hwMixed then initWithTiming() end
    initialized = true
end

--- Mixes extra entropy into the generator state.
--- @param data string The additional entropy to mix.
local function mix(data)
    expect(1, data, "string")
    mixHwSeed()
    state = blake3.digestKeyed(state, data)
end

--- Generates random bytes.
--- @param len number The desired output length.
--- @return string bytes
local function random(len)
    len = math.max(0, expect(1, len, "number"))
    lassert(initialized, "attempt to use an uninitialized random generator", 2)
    local ok, out = hw.random(len)
    if ok then return out end

    mixHwSeed()
    local msg = ("\0"):rep(len + 32)
    local nonce = ("\0"):rep(12)
    local out = chacha20.crypt(state, nonce, msg, 8, 0)
    state = out:sub(1, 32)
    return out:sub(33)
end

return {
    init = init,
    isInit = isInit,
    initWithTiming = initWithTiming,
    initAuto = initAuto,
    mix = mix,
    random = random,
}
]=]
F["vendor/ccryptolib/sha256.lua"] = [=[
--- The SHA256 cryptographic hash function.

local expect = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local packing = require "ccryptolib.internal.packing"
local hw = require "ccryptolib.internal.hw"

local rol = bit32.lrotate
local shr = bit32.rshift
local bxor = bit32.bxor
local bnot = bit32.bnot
local band = bit32.band
local unpack = unpack or table.unpack
local p1x8, fmt1x8 = packing.compilePack(">I8")
local p16x4, fmt16x4 = packing.compilePack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4")
local u16x4 = packing.compileUnpack(fmt16x4)
local p8x4, fmt8x4 = packing.compilePack(">I4I4I4I4I4I4I4I4")
local u8x4 = packing.compileUnpack(fmt8x4)

local function primes(n, exp)
    local out = {}
    local p = 2
    for i = 1, n do
        out[i] = bxor(p ^ exp % 1 * 2 ^ 32)
        repeat p = p + 1 until 2 ^ p % p == 2
    end
    return out
end

local K = primes(64, 1 / 3)

local h0 = primes(8, 1 / 2)

local function compress(h, w)
    local h0, h1, h2, h3, h4, h5, h6, h7 = unpack(h)
    local K = K

    -- Message schedule.
    for j = 17, 64 do
        local wf = w[j - 15]
        local w2 = w[j - 2]
        local s0 = bxor(rol(wf, 25), rol(wf, 14), shr(wf, 3))
        local s1 = bxor(rol(w2, 15), rol(w2, 13), shr(w2, 10))
        w[j] = w[j - 16] + s0 + w[j - 7] + s1
    end

    -- Block.
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 1, 64 do
        local s1 = bxor(rol(e, 26), rol(e, 21), rol(e, 7))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local temp1 = h + s1 + ch + K[j] + w[j]
        local s0 = bxor(rol(a, 30), rol(a, 19), rol(a, 10))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local temp2 = s0 + maj

        h = g
        g = f
        f = e
        e = d + temp1
        d = c
        c = b
        b = a
        a = temp1 + temp2
    end

    return {
        (h0 + a) % 2 ^ 32,
        (h1 + b) % 2 ^ 32,
        (h2 + c) % 2 ^ 32,
        (h3 + d) % 2 ^ 32,
        (h4 + e) % 2 ^ 32,
        (h5 + f) % 2 ^ 32,
        (h6 + g) % 2 ^ 32,
        (h7 + h) % 2 ^ 32,
    }
end

--- Hashes data using SHA256.
--- @param data string Input bytes.
--- @return string hash The 32-byte hash value.
local function digest(data)
    expect(1, data, "string")
    local ok, out = hw.sha256(data)
    if ok then return out end

    -- Pad input.
    local bitlen = #data * 8
    local padlen = -(#data + 9) % 64
    data = data .. "\x80" .. ("\0"):rep(padlen) .. p1x8(fmt1x8, bitlen)

    -- Digest.
    local h = h0
    for i = 1, #data, 64 do
        h = compress(h, {u16x4(fmt16x4, data, i)})
    end

    return p8x4(fmt8x4, unpack(h))
end

-- Reports once every ~10ms on a standard CCEmuX emulator.
local PBKDF2_CB_ITERATIONS = 50

--- Hashes a password using PBKDF2-HMAC-SHA256.
--- @param password string The password to hash.
--- @param salt string The password's salt.
--- @param iter number The number of iterations to perform.
--- @param progress fun(iter: number)? An optional function to periodically call with the current iteration number as argument.
--- @return string dk The 32-byte derived key.
local function pbkdf2(password, salt, iter, progress)
    expect(1, password, "string")
    expect(2, salt, "string")
    expect(3, iter, "number")
    lassert(iter % 1 == 0, "iteration number must be an integer", 2)
    lassert(iter > 0, "iteration number must be positive", 2)
    expect(4, progress, "function", "nil")

    -- Pad password.
    if #password > 64 then password = digest(password) end
    password = {u16x4(fmt16x4, password .. ("\0"):rep(64), 1)}

    -- Compute password blocks.
    local ikp = {}
    local okp = {}
    for i = 1, 16 do
        ikp[i] = bxor(password[i], 0x36363636)
        okp[i] = bxor(password[i], 0x5c5c5c5c)
    end

    local hikp = compress(h0, ikp)
    local hokp = compress(h0, okp)

    -- 96-byte padding.
    local pad96 = {2 ^ 31, 0, 0, 0, 0, 0, 0, 0x300}

    -- First iteration.
    local pre = p16x4(fmt16x4, unpack(ikp))
    local hs = {u8x4(fmt8x4, digest(pre .. salt .. "\0\0\0\1"), 1)}
    for i = 1, 8 do hs[i + 8] = pad96[i] end
    hs = compress(hokp, hs)

    -- Second iteration onwards.
    local out = {unpack(hs)}
    for i = 2, iter do
        for j = 1, 8 do hs[j + 8] = pad96[j] end
        hs = compress(hikp, hs)
        for j = 1, 8 do hs[j + 8] = pad96[j] end
        hs = compress(hokp, hs)
        for j = 1, 8 do out[j] = bxor(out[j], hs[j]) end
        if progress and i % PBKDF2_CB_ITERATIONS == 0 then progress(i) end
    end

    return p8x4(fmt8x4, unpack(out))
end

return {
    digest = digest,
    pbkdf2 = pbkdf2,
}
]=]
F["vendor/ccryptolib/util.lua"] = [=[
--- General utilities for handling byte strings.

local expect = require "cc.expect".expect
local random = require "ccryptolib.random"
local poly1305 = require "ccryptolib.poly1305"

--- Returns the hexadecimal version of a string.
--- @param str string A string.
--- @return string hex The hexadecimal version of the string.
local function toHex(str)
    expect(1, str, "string")
    return ("%02x"):rep(#str):format(str:byte(1, -1))
end

--- Converts back a string from hexadecimal.
--- @param hex string A hexadecimal string.
--- @return string? str The original string, or nil if the input is invalid.
local function fromHex(hex)
    expect(1, hex, "string")
    local out = {}
    local n = 0
    for c in hex:gmatch("%x%x") do
        n = n + 1
        out[n] = tonumber(c, 16)
    end
    if 2 * n == #hex then return string.char(table.unpack(out)) end
end

--- Compares two strings while mitigating secret leakage through timing.
--- @param a string
--- @param b string
--- @return boolean eq Whether a == b.
local function compare(a, b)
    expect(1, a, "string")
    expect(2, b, "string")
    if #a ~= #b then return false end
    local kaux = random.random(32)
    return poly1305.mac(kaux, a) == poly1305.mac(kaux, b)
end

return {
    toHex = toHex,
    fromHex = fromHex,
    compare = compare,
}
]=]
F["vendor/ccryptolib/x25519.lua"] = [=[
--- The X25519 key exchange scheme.

local expect = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local hw = require "ccryptolib.internal.hw"
local util = require "ccryptolib.internal.util"
local c25 = require "ccryptolib.internal.curve25519"

--- Computes the public key from a secret key.
--- @param sk string A random 32-byte secret key.
--- @return string pk The matching public key.
local function publicKey(sk)
    expect(1, sk, "string")
    assert(#sk == 32, "secret key length must be 32")
    local ok, out = hw.x25519PublicKey(sk)
    if ok then return out end
    return c25.encode(c25.scale(c25.mulG(util.bits(sk))))
end

--- Performs the key exchange.
--- @param sk string A Curve25519 secret key.
--- @param pk string A public key, usually derived from someone else's secret key.
--- @return string ss The 32-byte shared secret between both keys.
local function exchange(sk, pk)
    expect(1, sk, "string")
    lassert(#sk == 32, "secret key length must be 32", 2)
    expect(2, pk, "string")
    lassert(#pk == 32, "public key length must be 32", 2) --- @cast pk String32
    local ok, out = hw.x25519Exchange(sk, pk)
    if ok then return out end
    return c25.encode(c25.scale(c25.ladder8(c25.decode(pk), util.bits8(sk))))
end

return {
    publicKey = publicKey,
    exchange = exchange,
}
]=]
F["vendor/ccryptolib/x25519c.lua"] = [=[
local expect = require "cc.expect".expect
local lassert = require "ccryptolib.internal.util".lassert
local hw = require "ccryptolib.internal.hw"
local fq = require "ccryptolib.internal.fq"
local fp = require "ccryptolib.internal.fp"
local c25 = require "ccryptolib.internal.curve25519"
local sha512 = require "ccryptolib.internal.sha512"
local random = require "ccryptolib.random"

--- Masks an exchange secret key.
--- @param sk string A random 32-byte Curve25519 secret key.
--- @return string msk A masked secret key.
local function mask(sk)
    expect(1, sk, "string")
    lassert(#sk == 32, "secret key length must be 32", 2)
    local mask = random.random(32)
    local x = fq.decodeClamped(sk)
    local r = fq.decodeClamped(mask)
    local xr = fq.sub(x, r)
    return fq.encode(xr) .. mask
end

--- Masks a signature secret key.
--- @param sk string A random 32-byte Edwards25519 secret key.
--- @return string msk A masked secret key.
local function maskS(sk)
    expect(1, sk, "string")
    lassert(#sk == 32, "secret key length must be 32", 2)
    return mask(sha512.digest(sk):sub(1, 32))
end

--- Rerandomizes the masking on a masked key.
--- @param msk string A masked secret key.
--- @return string msk The same secret key, but with another mask.
local function remask(msk)
    expect(1, msk, "string")
    lassert(#msk == 64, "masked secret key length must be 64", 2)
    local newMask = random.random(32)
    local xr = fq.decode(msk:sub(1, 32))
    local r = fq.decodeClamped(msk:sub(33))
    local s = fq.decodeClamped(newMask)
    local xs = fq.add(xr, fq.sub(r, s))
    return fq.encode(xs) .. newMask
end

--- Returns the ephemeral exchange secret key of this masked key.
--- This is the second secret key in the "double key exchange" in @{exchange},
--- the first being the key that has been masked. The ephemeral key changes
--- every time @{remask} is called.
--- @param msk string A masked secret key.
--- @return string esk The ephemeral half of the masked secret key.
local function ephemeralSk(msk)
    expect(1, msk, "string")
    lassert(#msk == 64, "masked secret key length must be 64", 2)
    return msk:sub(33)
end

-- This does not have the same behavior on twist points. It is technically
-- inconsistent, but those points are all adversarial inputs, so we may as well
-- not care.
local function hwExchangeOnPoint(sk, P)
    local ok1, rP = hw.x25519Exchange(sk:sub(33), P)
    if not ok1 then return end

    local xr = fq.decode(sk:sub(1, 32))
    local r = fq.decodeClamped(sk:sub(33))
    local x = fq.add(xr, r)

    local ok2, xP = hw.x25519Exchange(fq.encodeClamped(x), P)
    if not ok2 then return end

    return true, xP, rP
end

local function exchangeOnPoint(sk, P)
    local xr = fq.decode(sk:sub(1, 32))
    local r = fq.decodeClamped(sk:sub(33))
    local rP, xrP, dP = c25.prac(P, fq.makeRuleset(fq.eighth(r), fq.eighth(xr)))

    -- Return early if P has small order or if r = xr. (1)
    if not rP then
        local out = fp.encode(fp.num(0))
        return out, out
    end

    local xP = c25.dadd(dP, rP, xrP)

    -- Extract coordinates for scaling.
    local Px, Pz = P[1], P[2]
    local xPx, xPz = xP[1], xP[2]
    local rPx, rPz = rP[1], rP[2]

    -- Ensure all Z coordinates are squares.
    Px, Pz = fp.mul(Px, Pz), fp.square(Pz)
    xPx, xPz = fp.mul(xPx, xPz), fp.square(xPz)
    rPx, rPz = fp.mul(rPx, rPz), fp.square(rPz)

    -- We're splitting the secret x into (x - r (mod q), r). The multiplication
    -- adds them back together, but this only works if P's order is q, which is
    -- not the case on the twist.
    -- As a result, we need to check if P is on the twist and return 0 so as to
    -- not leak part of x. We do this by checking the curve equation against P.
    -- The projective equation for curve25519 is Y²Z = X(X² + AXZ + Z²). Since Z
    -- is a square, checking validity means checking the right-hand side to be a
    -- square.
    local Px2 = fp.square(Px)
    local Pz2 = fp.square(Pz)
    local Pxz = fp.mul(Px, Pz)
    local APxz = fp.kmul(Pxz, 486662)
    local rhs = fp.mul(Px, fp.add(Px2, fp.carry(fp.add(APxz, Pz2))))

    -- Find the square root of 1 / (rhs * xPz * rPz).
    -- Neither rPz, xPz, nor rhs are 0:
    -- - If rhs was 0, then P would be low order, which would return at (1).
    -- - Since P isn't low order, clamping prevents the ladder from returning O.
    -- Since we've just squared both xPz and rPz, the root will exist iff rhs is
    -- a square. This checks the curve equation, so we're done.
    local root = fp.sqrtDiv(fp.num(1), fp.mul(fp.mul(xPz, rPz), rhs))
    if not root then
        local out = fp.encode(fp.num(0))
        return out, out
    end

    -- Get the inverses of both Z values.
    local xPzrPzInv = fp.mul(fp.square(root), rhs)
    local xPzInv = fp.mul(xPzrPzInv, rPz)
    local rPzInv = fp.mul(xPzrPzInv, xPz)

    -- Finish scaling and encode the output.
    return fp.encode(fp.mul(xPx, xPzInv)), fp.encode(fp.mul(rPx, rPzInv))
end

local G_ENC = fp.encode(fp.num(9))

--- Returns the X25519 public key of this masked key.
--- @param msk string A masked secret key.
local function publicKey(msk)
    expect(1, msk, "string")
    lassert(#msk == 64, "masked secret key length must be 64", 2)
    local ok, xP, rP = hwExchangeOnPoint(msk, G_ENC)
    if ok then return xP, rP end
    return (exchangeOnPoint(msk, c25.G))
end

--- Performs a double key exchange.
---
--- Returns 0 if the input public key has small order or if it isn't in the base
--- curve. This is different from standard X25519, which performs the exchange
--- even on the twist.
---
--- May incorrectly return 0 with negligible chance if the mask happens to match
--- the masked key. I haven't checked if clamping prevents that from happening.
---
--- @param sk string A masked secret key.
--- @param pk string An X25519 public key.
--- @return string sss The shared secret between the public key and the static half of the masked key.
--- @return string sse The shared secret betwen the public key and the ephemeral half of the masked key.
local function exchange(sk, pk)
    expect(1, sk, "string")
    lassert(#sk == 64, "masked secret key length must be 64", 2)
    expect(2, pk, "string")
    lassert(#pk == 32, "public key length must be 32", 2) --- @cast pk String32
    local ok, xP, rP = hwExchangeOnPoint(sk, pk)
    if ok then return xP, rP end
    return exchangeOnPoint(sk, c25.decode(pk))
end

return {
    mask = mask,
    remask = remask,
    publicKey = publicKey,
    ephemeralSk = ephemeralSk,
    exchange = exchange,
}
]=]

local DIR = "/bs-release"
if fs.exists(DIR) then fs.delete(DIR) end
for path, text in pairs(F) do
  local h = fs.open(DIR .. "/" .. path, "w")
  h.write(text)
  h.close()
end
F = nil
-- remove this bundle file now: the computer needs the disk space for the install
local me = shell.getRunningProgram()
if me and fs.exists(me) then fs.delete(me) end
local ok
if args[1] == "unpack" then
  print("Unpacked to " .. DIR)
  return
elseif args[1] then
  ok = shell.run(DIR .. "/install/install.lua", args[1])
else
  -- no role given: open the click-to-install setup screen
  ok = shell.run(DIR .. "/install/setup.lua")
end
if ok and fs.exists("/bs/.version") and not fs.exists("/bs/.installing") then
  fs.delete(DIR)
  print("Release files cleaned up.")
else
  print("Nothing was installed. Release files are still in " .. DIR .. " (run " .. DIR .. "/install/setup).")
end
