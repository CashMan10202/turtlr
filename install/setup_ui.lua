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
