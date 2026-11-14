-- Runs install/install.lua itself inside a fake computer.
local t = require("test.t")
local shim = require("test.cc_shim")
local sha = require("lib.sha256")

local T = {}

local function slurp(path)
  local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end

-- a tiny release: the real installer files plus one role
local function release()
  local files = {
    ["install/install.lua"] = slurp("install/install.lua"),
    ["install/installer_core.lua"] = slurp("install/installer_core.lua"),
    ["lib/sha256.lua"] = slurp("lib/sha256.lua"),
    ["roles/gps/config.lua"] = "return { set = false }",
  }
  local e = { path = "roles/gps/config.lua", dest = "/bs/role/config.lua",
    size = #files["roles/gps/config.lua"], sha256 = sha.hex(files["roles/gps/config.lua"]) }
  files["manifest.lua"] = ('return { version = "0.9.0", roles = { gps = { { path = %q, dest = %q, size = %d, sha256 = %q } } } }')
    :format(e.path, e.dest, e.size, e.sha256)
  return files
end

local function run(e, program, args, extra)
  local printed, loaded = {}, {}
  local env
  env = setmetatable({
    fs = e.fs, os = e.os,
    shell = { getRunningProgram = function() return program end },
    package = { path = "?.lua" },
    print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end,
    printError = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end,
    write = function() end, sleep = function() end,
    read = function() return "1" end,
    require = function(name)
      if loaded[name] then return loaded[name] end
      local rel = name:gsub("%.", "/")
      for pattern in env.package.path:gmatch("[^;]+") do
        local src = e.read((pattern:gsub("%?", rel)))
        if src then
          loaded[name] = assert(load(src, "=" .. name, "t", env))()
          return loaded[name]
        end
      end
      error("module not found: " .. name .. " in " .. env.package.path)
    end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do env[k] = v end
  local ok, err = pcall(assert(load(e.read(program), "=install", "t", env)), table.unpack(args))
  return ok, err, table.concat(printed, "\n")
end

function T.installs_from_a_floppy()
  local e = shim.new()
  for path, content in pairs(release()) do e.write("/disk/buildservice/" .. path, content) end
  local ok, err, out = run(e, "disk/buildservice/install/install.lua", { "gps" })
  t.ok(ok, tostring(err))
  t.eq(e.read("/bs/role/config.lua"), "return { set = false }")
  t.ok(out:find("Done", 1, true), out)
end

function T.role_menu_is_used_when_no_role_given()
  local e = shim.new()
  for path, content in pairs(release()) do e.write("/disk/buildservice/" .. path, content) end
  local ok, err = run(e, "disk/buildservice/install/install.lua", {})
  t.ok(ok, tostring(err))
  t.ok(e.fs.exists("/bs/role/config.lua"))
end

function T.installs_from_the_web_with_only_install_lua_present()
  local e = shim.new()
  local files = release()
  e.write("/install.lua", files["install/install.lua"])
  local http = { get = function(url)
    local path = url:match("^https://host%.test/rel/(.+)$")
    local body = path and files[path]
    if not body then return nil, "404 " .. url end
    return { readAll = function() return body end, close = function() end }
  end }
  local ok, err, out = run(e, "install.lua", { "gps", "https://host.test/rel" }, { http = http })
  t.ok(ok, tostring(err))
  t.eq(e.read("/bs/role/config.lua"), "return { set = false }")
  t.ok(not e.fs.exists("/bs/.boot"), "bootstrap files left behind")
  t.ok(out:find("Done", 1, true), out)
end

function T.web_install_rejects_plain_http()
  local e = shim.new()
  e.write("/install.lua", release()["install/install.lua"])
  local called = false
  local ok, err = run(e, "install.lua", { "gps", "http://host.test/rel" },
    { http = { get = function() called = true end } })
  t.ok(not ok)
  t.ok(tostring(err):find("https", 1, true))
  t.ok(not called, "must not contact a plain-http address")
end

return T
