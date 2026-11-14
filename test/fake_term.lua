-- Fake CC terminal for tests: keeps the text on screen so tests can read it and find buttons.
local M = {}

function M.new(w, h, colour)
  local rows, cx, cy = {}, 1, 1
  local function blank() return (" "):rep(w) end
  for y = 1, h do rows[y] = blank() end
  local term = {}
  function term.getSize() return w, h end
  function term.setCursorPos(x, y) cx, cy = math.floor(x), math.floor(y) end
  function term.getCursorPos() return cx, cy end
  function term.isColour() return colour ~= false end
  term.isColor = term.isColour
  function term.clear() for y = 1, h do rows[y] = blank() end end
  function term.clearLine() if rows[cy] then rows[cy] = blank() end end
  function term.setCursorBlink() end
  function term.scroll(n)
    for _ = 1, n do table.remove(rows, 1); rows[h] = blank() end
  end
  function term.write(s)
    s = tostring(s)
    if rows[cy] then
      for i = 1, #s do
        local x = cx + i - 1
        if x >= 1 and x <= w then rows[cy] = rows[cy]:sub(1, x - 1) .. s:sub(i, i) .. rows[cy]:sub(x + 1) end
      end
    end
    term.overflow = term.overflow or (cy > h or cy < 1 or cx + #s - 1 > w)
    cx = cx + #s
  end
  for _, name in ipairs({ "setTextColour", "setTextColor", "setBackgroundColour", "setBackgroundColor" }) do
    term[name] = function() end
  end
  -- helpers for tests
  function term.text() return table.concat(rows, "\n") end
  function term.find(needle)
    for y = 1, h do
      local x = rows[y]:find(needle, 1, true)
      if x then return x, y end
    end
  end
  -- print()/write() replacements that draw on this terminal
  function term.print(...)
    local s = table.concat({ ... }, " ")
    for line in (s .. "\n"):gmatch("(.-)\n") do
      term.write(line:sub(1, w))
      cx, cy = 1, cy + 1
      if cy > h then term.scroll(1); cy = h end
    end
  end
  return term
end

return M
