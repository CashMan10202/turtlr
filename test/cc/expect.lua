-- Stand-in for CC's cc.expect so vendored libraries load outside Minecraft.
local function expect(index, value, ...)
  local got = type(value)
  for _, want in ipairs({ ... }) do if got == want then return value end end
  error(("bad argument #%d (expected %s, got %s)"):format(index, table.concat({ ... }, " or "), got), 3)
end
return { expect = expect, field = function(tbl, key, ...) return expect(key, tbl[key], ...) end,
  range = function(n) return n end }
