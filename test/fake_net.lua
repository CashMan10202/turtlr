-- Fake wireless network for tests. Every modem hears every other modem on channels it has open.
local fake_net = {}

function fake_net.new()
  local net = { sent = 0 }
  local modems, taps = {}, {}

  -- fn(fromName, channel, payload) may return a replacement payload, or false to drop the frame
  function net.tap(fn) taps[#taps + 1] = fn end

  function net.modem(name)
    local open, queue = {}, {}
    local m = { name = name, queue = queue }
    function m.open(ch) open[ch] = true end
    function m.close(ch) open[ch] = nil end
    function m.isOpen(ch) return open[ch] == true end
    function m.isWireless() return true end
    function m.transmit(ch, reply, payload)
      net.sent = net.sent + 1
      for _, tap in ipairs(taps) do
        local r = tap(name, ch, payload)
        if r == false then return end
        if r ~= nil then payload = r end
      end
      for other, om in pairs(modems) do
        if other ~= name and om.isOpen(ch) and not om.dead then
          om.queue[#om.queue + 1] = { "modem_message", other, ch, reply, payload, 10 }
        end
      end
    end
    modems[name] = m
    return m
  end

  -- Next queued event for a modem (as os.pullEvent would return it), or nil.
  function net.next(name)
    return table.remove(modems[name].queue, 1)
  end

  function net.pending(name) return #modems[name].queue end

  -- Simulate a computer being switched off / on.
  function net.kill(name) modems[name].dead = true; modems[name].queue = {} end
  function net.revive(name) modems[name].dead = nil end

  return net
end

return fake_net
