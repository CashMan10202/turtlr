-- Test runner: lua5.2 test/run.lua [pattern]
-- Runs every test/*_test.lua and test/*/*_test.lua whose path contains pattern.
package.path = "./?.lua;./?/init.lua;" .. package.path
local pattern = arg and arg[1]

local files = {}
local p = io.popen("ls test/*_test.lua test/*/*_test.lua 2>/dev/null")
for line in p:lines() do
  if not pattern or line:find(pattern, 1, true) then files[#files + 1] = line end
end
p:close()
table.sort(files)

local pass, fail = 0, 0
for _, file in ipairs(files) do
  local mod = file:gsub("%.lua$", ""):gsub("/", ".")
  local ok, tests = pcall(require, mod)
  if not ok or type(tests) ~= "table" then
    fail = fail + 1
    print("FAIL " .. file .. " (load): " .. tostring(tests))
  else
    local names = {}
    for name in pairs(tests) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local good, e = xpcall(tests[name], debug.traceback)
      if good then
        pass = pass + 1
      else
        fail = fail + 1
        print("FAIL " .. file .. " :: " .. name .. "\n  " .. tostring(e):gsub("\n", "\n  "))
      end
    end
  end
end

print(("PASS %d / FAIL %d"):format(pass, fail))
if #files == 0 then print("no test files found") end
os.exit((fail == 0 and #files > 0) and 0 or 1)
