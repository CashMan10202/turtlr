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
