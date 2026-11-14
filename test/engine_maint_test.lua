local t = require("test.t")
local H = require("test.engine_helper")
local T = {}

local function scrubAll(E, rack)
  local total = { checked = 0, bad = 0, repaired = 0, lost = 0 }
  for _ = 1, #rack.devs do
    local r = E.scrubStep()
    for k in pairs(total) do total[k] = total[k] + r[k] end
  end
  return total
end

local function copiesOk(rack, want)
  local holders = {}
  for _, ctl in ipairs(rack.ctl) do
    for _, id in ipairs(ctl.keys()) do holders[id] = (holders[id] or 0) + 1 end
  end
  for id, n in pairs(holders) do t.eq(n, want, "cell " .. id .. " has " .. n .. " copies") end
end

function T.scrub_repairs_a_corrupt_replica()
  local rack = H.rack(3)
  local E = H.boot(rack)
  local v = H.blob(700)
  E.put("jobs", "j", v)
  rack.ctl[1].corrupt()
  local r = scrubAll(E, rack)
  t.eq(r.bad, 1); t.eq(r.repaired, 1); t.eq(r.lost, 0)
  copiesOk(rack, 2)
  -- every copy is now good: kill each device in turn and the value is still readable
  for i = 1, 3 do
    local saved = rack.ctl[i].dump()
    rack.ctl[i].wipe()
    t.eq(H.boot(rack).get("jobs", "j"), v)
    rack.ctl[i].set(saved)
  end
end

function T.scrub_restores_copies_after_a_device_is_wiped()
  local rack = H.rack(3)
  local E = H.boot(rack)
  local want = {}
  for i = 1, 4 do want["k" .. i] = H.blob(200 + i * 100, i); E.put("jobs", "k" .. i, want["k" .. i]) end
  rack.ctl[2].wipe()
  local r = scrubAll(E, rack)
  t.ok(r.repaired >= 1)
  copiesOk(rack, 2)
  for k, v in pairs(want) do t.eq(E.get("jobs", k), v) end
  t.eq(E.health().degraded, 0)
end

function T.scrub_reports_lost_data()
  local rack = H.rack(2)
  local E = H.boot(rack)
  E.put("jobs", "gone", H.blob(250))
  E.put("jobs", "fine", "ok")
  for _, id in ipairs(rack.ctl[1].keys()) do
    if rack.ctl[1].dump()[id]:find("jobs/gone", 1, true) then rack.ctl[1].corrupt(id); rack.ctl[2].corrupt(id) end
  end
  local r = scrubAll(E, rack)
  t.eq(r.lost, 1)
  t.eq(select(2, E.get("jobs", "gone")), "corrupt")
  t.eq(E.get("jobs", "fine"), "ok")
  t.eq(E.health().lost, 1)
  -- overwriting a lost key heals it
  t.ok(E.put("jobs", "gone", "back"))
  t.eq(E.get("jobs", "gone"), "back")
  t.eq(E.health().lost, 0)
end

function T.scrub_survives_an_unreadable_device()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "j", "v")
  rack.ctl[1].fail(1)
  local r = E.scrubStep()
  t.eq(r.device, "nbt_01"); t.eq(r.error, "io")
  t.eq(E.health().devices[1].ok, false)
  scrubAll(E, rack)
  t.eq(E.health().devices[1].ok, true)
end

function T.health_numbers()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "a", H.blob(100)); E.put("players", "b", H.blob(100))
  local h = E.health()
  t.eq(#h.devices, 3)
  t.eq(h.keys, 2); t.eq(h.bytes, 200); t.eq(h.capacity, 12000)
  t.eq(h.degraded, 0); t.eq(h.lost, 0)
  local used, cells = 0, 0
  for _, d in ipairs(h.devices) do used = used + d.used; cells = cells + d.cells; t.eq(d.ok, true) end
  t.eq(cells, 4); t.ok(used > 400 and h.used == used)
end

function T.rebalance_evens_out_fill()
  local rack = H.rack(2, 20000)
  local E = H.boot(rack, { deviceMaxBytes = 20000, replicas = 1 })
  local want = {}
  for i = 1, 20 do want["k" .. i] = H.blob(880, i); E.put("jobs", "k" .. i, want["k" .. i]) end
  -- two new empty devices join
  local more = H.rack(2, 20000)
  more.devs[1].name, more.devs[2].name = "nbt_03", "nbt_04"
  E.addDevice(more.devs[1]); E.addDevice(more.devs[2])
  local moved = E.rebalance()
  t.ok(moved > 0)
  local h = E.health()
  local lo, hi = math.huge, 0
  for _, d in ipairs(h.devices) do lo = math.min(lo, d.used); hi = math.max(hi, d.used) end
  t.ok((hi - lo) / 20000 <= 0.3, "still uneven: " .. lo .. ".." .. hi)
  for k, v in pairs(want) do t.eq(E.get("jobs", k), v) end
  t.eq(E.rebalance(), 0)
end

function T.rebalance_never_puts_two_copies_on_one_device()
  local rack = H.rack(3, 20000)
  local E = H.boot(rack, { deviceMaxBytes = 20000 })
  for i = 1, 10 do E.put("jobs", "k" .. i, H.blob(280, i)) end
  local more = H.rack(1, 20000); more.devs[1].name = "nbt_09"
  E.addDevice(more.devs[1])
  E.rebalance()
  for _, ctl in ipairs({ rack.ctl[1], rack.ctl[2], rack.ctl[3], more.ctl[1] }) do
    local seen = {}
    for _, id in ipairs(ctl.keys()) do t.ok(not seen[id]); seen[id] = true end
  end
  t.eq(E.health().degraded, 0)
end

function T.remove_device_drains_it_first()
  local rack = H.rack(3, 20000)
  local E = H.boot(rack, { deviceMaxBytes = 20000 })
  local want = {}
  for i = 1, 6 do want["k" .. i] = H.blob(280, i); E.put("jobs", "k" .. i, want["k" .. i]) end
  t.ok(E.removeDevice("nbt_02"))
  t.eq(#rack.ctl[2].keys(), 0)
  t.eq(#E.health().devices, 2)
  t.eq(E.health().degraded, 0)
  for k, v in pairs(want) do t.eq(E.get("jobs", k), v) end
  t.eq(select(2, E.removeDevice("nbt_02")), "not_found")
end

function T.remove_device_refuses_when_data_would_not_fit()
  local rack = H.rack(2, 1500)
  local E = H.boot(rack, { deviceMaxBytes = 1500, replicas = 1 })
  E.put("jobs", "a", H.blob(600, 1)); E.put("jobs", "b", H.blob(600, 2))
  local ok, err = E.removeDevice("nbt_01")
  t.eq(ok, nil); t.eq(err, "no_space")
  t.eq(E.get("jobs", "a"), H.blob(600, 1)); t.eq(E.get("jobs", "b"), H.blob(600, 2))
end

function T.hot_cache_serves_repeat_reads_and_is_invalidated()
  local rack = H.rack(3)
  local E = H.boot(rack, { hot = { jobs = true }, cacheBytes = 500 })
  E.put("jobs", "j", "v1"); E.put("logs", "l", "cold")
  t.eq(E.get("jobs", "j"), "v1")
  local reads = rack.reads()
  t.eq(E.get("jobs", "j"), "v1")
  t.eq(rack.reads(), reads, "hot read touched a device")
  E.get("logs", "l"); local r2 = rack.reads(); E.get("logs", "l")
  t.ok(rack.reads() > r2, "cold namespace should not be cached")
  E.put("jobs", "j", "v2")
  t.eq(E.get("jobs", "j"), "v2")
  E.delete("jobs", "j")
  t.eq(select(2, E.get("jobs", "j")), "not_found")
end

function T.hot_cache_is_bounded()
  local rack = H.rack(3, 20000)
  local E = H.boot(rack, { deviceMaxBytes = 20000, hot = { jobs = true }, cacheBytes = 500 })
  for i = 1, 5 do E.put("jobs", "k" .. i, H.blob(200, i)); E.get("jobs", "k" .. i) end
  t.ok(E.health().cacheBytes <= 500)
  E.put("jobs", "big", H.blob(900)); E.get("jobs", "big")
  t.ok(E.health().cacheBytes <= 500)
  for i = 1, 5 do t.eq(E.get("jobs", "k" .. i), H.blob(200, i)) end
end

function T.snapshot_round_trip_skips_the_scan()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "a", H.blob(700, 1)); E.put("players", "b", "bee")
  local snap = E.snapshot()
  t.ok(type(snap) == "string" and not snap:find("[^\32-\126\n]"))
  local engine = require("roles.storage.engine")
  local E2 = engine.new({ devices = rack.devs, crypto = require("lib.crypto"), replicas = 2, shardBytes = 300,
    deviceMaxBytes = 4000, clock = function() return 1 end })
  local reads = rack.reads()
  t.ok(E2.loadSnapshot(snap))
  t.eq(rack.reads(), reads)
  t.eq(E2.get("jobs", "a"), H.blob(700, 1)); t.eq(E2.get("players", "b"), "bee")
  t.eq(E2.list("jobs"), { "a" })
end

function T.bad_snapshot_is_refused()
  local E = H.boot(H.rack(3))
  for _, junk in ipairs({ "", "garbage", "BKSNAP 1\nnot|a|line\n", 5, "BKSNAP 9\n" }) do
    t.eq(E.loadSnapshot(junk), nil)
  end
end

function T.stale_snapshot_falls_back_to_rebuild_on_miss()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "a", "old")
  local snap = E.snapshot()
  E.put("jobs", "a", "new") -- the snapshot is now out of date
  local engine = require("roles.storage.engine")
  local E2 = engine.new({ devices = rack.devs, crypto = require("lib.crypto"), replicas = 2, shardBytes = 300,
    deviceMaxBytes = 4000, clock = function() return 1 end })
  E2.loadSnapshot(snap)
  t.eq(E2.get("jobs", "a"), "new")
end

return T
