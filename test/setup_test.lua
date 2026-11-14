local t = require("test.t")
local shim = require("test.cc_shim")
local fake_term = require("test.fake_term")
local sha = require("lib.sha256")
local ui = require("install.setup_ui")

local T = {}

-- pure logic ----------------------------------------------------------------

function T.next_step_walks_through_setup_in_order()
  t.eq(ui.nextStep({ release = true }), "install")
  t.eq(ui.nextStep({}), "getrelease")
  local s = { role = "storage", isBase = true }
  t.eq(ui.nextStep(s), "needfloppy")
  s.floppy = true
  t.eq(ui.nextStep(s), "mkkeys")
  s.floppyKeys = true
  t.eq(ui.nextStep(s), "loadkeys")
  s.hasKeys = true
  t.eq(ui.nextStep(s), "reboot")
  t.eq(ui.nextStep({ role = "compute", isBase = true, hasKeys = true }), "storetest")
  t.eq(ui.nextStep({ role = "worker" }), "verify")
  t.eq(ui.nextStep({ role = "pocket" }), "verify")
end

local function ids(items)
  local out = {}
  for i, it in ipairs(items) do out[i] = it.id end
  return out
end

function T.menu_only_offers_what_is_possible()
  t.eq(ids(ui.menu({})), { "getrelease", "verify", "exit" })
  t.eq(ids(ui.menu({ release = true })), { "install", "verify", "exit" })
  t.eq(ids(ui.menu({ release = true, role = "storage", isBase = true, floppy = true })),
    { "mkkeys", "install", "verify", "reboot", "exit" })
  t.eq(ids(ui.menu({ role = "compute", isBase = true, floppy = true, floppyKeys = true, hasKeys = true })),
    { "storetest", "loadkeys", "mkkeys", "verify", "reboot", "exit" })
  -- the recommended step is first and flagged
  local m = ui.menu({ release = true })
  t.eq(m[1].recommended, true)
  for i = 2, #m do t.eq(m[i].recommended, nil) end
end

function T.layout_fits_every_screen_size()
  for _, size in ipairs({ { 51, 19 }, { 39, 13 }, { 26, 20 } }) do
    local w, h = size[1], size[2]
    for count = 1, 14 do
      local L = ui.layout(count, w, h, 6)
      t.ok(L.perPage >= 2, "no room for buttons on " .. w .. "x" .. h)
      local seen = {}
      for i = 1, math.min(count, L.perPage) do
        local r = L.rect(i)
        t.ok(r.x >= 1 and r.x + r.w - 1 <= w and r.y >= 6 and r.y <= h - 1, "button off screen")
        t.ok(not seen[r.y], "buttons overlap")
        seen[r.y] = true
      end
    end
  end
end

function T.hit_testing()
  local L = ui.layout(3, 51, 19, 6)
  local r2 = L.rect(2)
  t.eq(ui.hit(L, 3, r2.x, r2.y), 2)
  t.eq(ui.hit(L, 3, r2.x + r2.w - 1, r2.y), 2)
  t.eq(ui.hit(L, 3, 1, 1), nil)
  t.eq(ui.hit(L, 3, r2.x, r2.y + 1), nil) -- the gap between buttons
end

function T.pages()
  local pages = ui.paginate({ "a", "b", "c", "d", "e" }, 3)
  t.eq(pages, { { "a", "b" }, { "c", "d" }, { "e" } }) -- one slot per page is kept for "More"
  t.eq(ui.paginate({ "a", "b", "c" }, 3), { { "a", "b", "c" } })
  t.eq(ui.paginate({}, 3), { {} })
end

-- the real setup program on a fake computer ---------------------------------

local function slurp(path)
  local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end

local function computer(w, h, opts)
  opts = opts or {}
  local e = shim.new()
  local term = fake_term.new(w or 51, h or 19)
  local c = { e = e, term = term, ran = {}, events = {} }
  if opts.release ~= false then
    local files = {
      ["install/setup.lua"] = slurp("install/setup.lua"),
      ["install/setup_ui.lua"] = slurp("install/setup_ui.lua"),
      ["install/installer_core.lua"] = slurp("install/installer_core.lua"),
      ["install/keys_core.lua"] = slurp("install/keys_core.lua"),
      ["lib/sha256.lua"] = slurp("lib/sha256.lua"),
      ["roles/storage/config.lua"] = "return { id = 1 }",
      ["roles/pocket/config.lua"] = "return {}",
    }
    local function entry(path, dest)
      return ('{ path = %q, dest = %q, size = %d, sha256 = %q }'):format(path, dest, #files[path], sha.hex(files[path]))
    end
    files["manifest.lua"] = 'return { version = "9.9.9", roles = { storage = { '
      .. entry("roles/storage/config.lua", "/bs/role/config.lua") .. ' }, pocket = { '
      .. entry("roles/pocket/config.lua", "/bs/role/config.lua") .. ' } } }'
    for path, content in pairs(files) do e.write("/bs-release/" .. path, content) end
  end
  local loaded = {}
  local env
  env = setmetatable({
    fs = e.fs, term = term, peripheral = e.peripheral,
    colours = setmetatable({}, { __index = function() return 1 end }),
    print = term.print, write = term.write, sleep = function() end,
    os = { pullEvent = function()
      local ev = table.remove(c.events, 1)
      if not ev then error("__out_of_events", 0) end
      if type(ev) == "function" then ev = ev() end
      return table.unpack(ev)
    end, reboot = function() c.rebooted = true; error("__reboot", 0) end },
    shell = { getRunningProgram = function() return opts.program or "bs-release/install/setup.lua" end,
      run = function(...) c.ran[#c.ran + 1] = table.concat({ ... }, " "); return true end },
    package = { path = "?.lua" },
    require = function(name)
      if loaded[name] then return loaded[name] end
      local rel = name:gsub("%.", "/")
      for pattern in env.package.path:gmatch("[^;]+") do
        local src = e.read((pattern:gsub("%?", rel)))
        if src then loaded[name] = assert(load(src, "=" .. name, "t", env))(); return loaded[name] end
      end
      error("module not found: " .. name)
    end,
  }, { __index = _G })
  -- click the button whose label contains `label` (resolved when the event is pulled)
  function c.click(label)
    c.events[#c.events + 1] = function()
      local x, y = term.find(label)
      if not x then error("no button '" .. label .. "' on screen:\n" .. term.text(), 0) end
      return { "mouse_click", 1, x, y }
    end
  end
  function c.key(ch) c.events[#c.events + 1] = { "char", ch } end
  function c.run()
    local ok, err = pcall(assert(load(e.read("/bs-release/install/setup.lua") or slurp("install/setup.lua"),
      "=setup", "t", env)))
    if not ok and err ~= "__out_of_events" and err ~= "__reboot" then error(err, 0) end
    return ok
  end
  return c
end

function T.fresh_computer_install_by_clicking()
  local c = computer()
  c.click("Install a role")
  c.click("storage")
  c.click("OK")
  c.run()
  t.eq(load(c.e.read("/bs/.version"), "v", "t", {})().role, "storage")
  local screen = c.term.text()
  t.ok(screen:find("Role: storage 9.9.9", 1, true), screen)
  t.ok(screen:find("Keys: missing", 1, true), screen)
  t.ok(not c.term.overflow, "something was drawn off screen")
end

function T.number_keys_work_and_q_quits()
  local c = computer()
  c.key("1")       -- Install a role
  c.key("1")       -- first role alphabetically: pocket
  c.key(" ")       -- dismiss result
  c.key("q")
  t.eq(c.run(), true)
  t.eq(load(c.e.read("/bs/.version"), "v", "t", {})().role, "pocket")
end

function T.runs_the_check_program_with_the_chosen_option()
  local c = computer()
  c.click("Check this computer")
  c.click("Quick check")
  c.key(" ")
  c.click("Check this computer")
  c.click("pixel test")
  c.key(" ")
  c.key("q")
  c.run()
  t.eq(c.ran, { "/bs-release/install/verify.lua", "/bs-release/install/verify.lua --gfx" })
end

function T.keys_buttons_follow_the_floppy()
  local c = computer()
  c.e.write("/bs/.version", 'return { role = "storage", version = "9.9.9" }')
  c.e.fs.makeDir("/disk")
  c.click("Make new keys")
  c.key(" ")
  c.key("q")
  c.run()
  t.eq(c.ran, { "/bs-release/install/mkkeys.lua" })
  -- floppy now has keys for this role: the recommended button becomes "Load keys"
  local c2 = computer()
  c2.e.write("/bs/.version", 'return { role = "storage", version = "9.9.9" }')
  c2.e.write("/disk/bskeys/storage.lua", "return {}")
  c2.click("Load keys")
  c2.key(" ")
  c2.key("q")
  c2.run()
  t.eq(c2.ran, { "/bs-release/install/mkkeys.lua load storage" })
end

function T.reboot_button()
  local c = computer()
  c.e.write("/bs/.version", 'return { role = "pocket", version = "9.9.9" }')
  c.click("Reboot")
  c.run()
  t.eq(c.rebooted, true)
  -- the unpacked release (about 340 KB) must not be left on the disk after a reboot
  t.ok(not c.e.fs.exists("/bs-release"), "release files left behind")
end

function T.fits_pocket_and_turtle_screens()
  for _, size in ipairs({ { 26, 20 }, { 39, 13 } }) do
    local c = computer(size[1], size[2])
    c.click("Install a role")
    c.click("pocket")
    c.key(" ")
    c.click("Check this computer")
    c.click("Back")
    c.key("q")
    c.run()
    t.ok(not c.term.overflow, "drawn off a " .. size[1] .. "x" .. size[2] .. " screen:\n" .. c.term.text())
    t.ok(c.e.fs.exists("/bs/.version"))
  end
end

function T.failed_install_is_shown_not_thrown()
  local c = computer()
  c.e.write("/bs-release/roles/storage/config.lua", "tampered")
  c.click("Install a role")
  c.click("storage")
  c.run()
  t.ok(c.term.text():find("nothing was changed", 1, true), c.term.text())
  t.ok(not c.e.fs.exists("/bs/.version"))
end

function T.without_a_release_it_explains_how_to_get_one()
  local c = computer(51, 19, { release = false, program = "bs/install/setup.lua" })
  for _, name in ipairs({ "setup", "setup_ui", "installer_core", "keys_core" }) do
    c.e.write("/bs/install/" .. name .. ".lua", slurp("install/" .. name .. ".lua"))
  end
  c.e.write("/bs/lib/sha256.lua", slurp("lib/sha256.lua"))
  c.click("Get the release")
  c.run()
  t.ok(c.term.text():find("buildkit", 1, true), c.term.text())
end

return T
