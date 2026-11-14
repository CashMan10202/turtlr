local t = require("test.t")
local H = require("test.engine_helper")
local T = {}

function T.put_get_small_and_multi_shard()
  local rack = H.rack(3)
  local E = H.boot(rack)
  t.ok(E.put("jobs", "j1", "hello"))
  t.eq(E.get("jobs", "j1"), "hello")
  local big = H.blob(800)
  t.ok(E.put("schematics", "s1", big))
  t.eq(E.get("schematics", "s1"), big)
  t.eq(E.stat("schematics", "s1"), { size = 800, ver = 1, shards = 3 })
  t.ok(E.put("jobs", "empty", ""))
  t.eq(E.get("jobs", "empty"), "")
end

function T.binary_safe()
  local E = H.boot(H.rack(3))
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  all = table.concat(all)
  t.ok(E.put("logs", "bin", all))
  t.eq(E.get("logs", "bin"), all)
end

function T.each_shard_is_on_two_different_devices()
  local rack = H.rack(4)
  local E = H.boot(rack)
  E.put("jobs", "j", H.blob(700))
  local holders = {}
  for i, ctl in ipairs(rack.ctl) do
    for _, id in ipairs(ctl.keys()) do
      holders[id] = holders[id] or {}
      holders[id][#holders[id] + 1] = i
    end
  end
  local n = 0
  for _, devs in pairs(holders) do
    n = n + 1
    t.eq(#devs, 2)
  end
  t.eq(n, 3)
end

function T.overwrite_and_delete()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "j", H.blob(700, 1))
  local v2 = H.blob(350, 2)
  t.ok(E.put("jobs", "j", v2))
  t.eq(E.get("jobs", "j"), v2)
  t.eq(E.stat("jobs", "j").ver, 2)
  t.eq(rack.cells(), 4) -- 2 shards x 2 replicas; nothing of version 1 left
  t.ok(E.delete("jobs", "j"))
  local v, err = E.get("jobs", "j")
  t.eq(v, nil); t.eq(err, "not_found")
  t.eq(E.stat("jobs", "j"), nil)
  t.eq(rack.cells(), 0)
  local ok, e2 = E.delete("jobs", "j")
  t.eq(ok, nil); t.eq(e2, "not_found")
end

function T.list_is_sorted_filtered_and_paged()
  local E = H.boot(H.rack(3, 20000), { deviceMaxBytes = 20000 })
  for _, k in ipairs({ "b2", "a1", "b1", "c1", "b3" }) do E.put("jobs", k, "x") end
  E.put("players", "b9", "x")
  t.eq({ E.list("jobs") }, { { "a1", "b1", "b2", "b3", "c1" }, false })
  t.eq({ E.list("jobs", "b") }, { { "b1", "b2", "b3" }, false })
  t.eq({ E.list("jobs", "b", nil, 2) }, { { "b1", "b2" }, true })
  t.eq({ E.list("jobs", "b", "b2", 2) }, { { "b3" }, false })
  t.eq({ E.list("recipes") }, { {}, false })
end

function T.bad_names_and_sizes()
  local E = H.boot(H.rack(3))
  for _, bad in ipairs({ { "nope", "k" }, { "jobs", "" }, { "jobs", "a|b" }, { "jobs", "a/b" }, { "jobs", "a b" },
    { "jobs", ("k"):rep(97) }, { "jobs", 5 }, { 5, "k" } }) do
    local ok, err = E.put(bad[1], bad[2], "v")
    t.eq(ok, nil); t.eq(err, "bad_key")
    t.eq(select(2, E.get(bad[1], bad[2])), "bad_key")
  end
  t.eq(select(2, E.put("jobs", "k", 5)), "bad_value")
  local Esmall = H.boot(H.rack(3), {})
  t.eq(select(2, Esmall.put("jobs", "k", ("x"):rep(4194305))), "too_big")
end

function T.rebuild_reproduces_everything()
  local rack = H.rack(4, 20000)
  local E = H.boot(rack, { deviceMaxBytes = 20000 })
  local want = {}
  for i = 1, 12 do
    want["k" .. i] = H.blob(50 + i * 60, i)
    E.put("jobs", "k" .. i, want["k" .. i])
  end
  E.delete("jobs", "k3"); want.k3 = nil
  E.put("jobs", "k4", "changed"); want.k4 = "changed"
  local E2 = H.boot(rack, { deviceMaxBytes = 20000 })
  local keys = E2.list("jobs")
  t.eq(#keys, 11)
  for k, v in pairs(want) do t.eq(E2.get("jobs", k), v, k) end
  t.eq(E2.stat("jobs", "k4").ver, 2)
end

function T.single_device_still_works_with_two_replicas_configured()
  local rack = H.rack(1)
  local E = H.boot(rack)
  t.ok(E.put("jobs", "j", H.blob(500)))
  t.eq(E.get("jobs", "j"), H.blob(500))
  t.eq(rack.cells(), 2)
end

function T.one_corrupt_replica_is_survivable()
  local rack = H.rack(2)
  local E = H.boot(rack)
  local v = H.blob(250)
  E.put("jobs", "j", v)
  rack.ctl[1].corrupt()
  t.eq(E.get("jobs", "j"), v)
  rack.ctl[1].wipe()
  t.eq(E.get("jobs", "j"), v)
end

function T.device_that_throws_on_read_is_skipped()
  local rack = H.rack(2)
  local E = H.boot(rack)
  E.put("jobs", "j", "value")
  rack.ctl[1].fail(1)
  t.eq(E.get("jobs", "j"), "value")
  rack.ctl[2].fail(1)
  t.eq(E.get("jobs", "j"), "value")
end

function T.all_replicas_corrupt_is_reported()
  local rack = H.rack(2)
  local E = H.boot(rack)
  E.put("jobs", "j", H.blob(250))
  rack.ctl[1].corrupt(); rack.ctl[2].corrupt()
  local v, err = E.get("jobs", "j")
  t.eq(v, nil); t.eq(err, "corrupt")
end

function T.full_farm_fails_cleanly()
  local rack = H.rack(2, 1500)
  local E = H.boot(rack, { deviceMaxBytes = 1500 })
  t.ok(E.put("jobs", "keep", H.blob(300, 7)))
  local before = rack.cells()
  local ok, err = E.put("jobs", "huge", H.blob(3000))
  t.eq(ok, nil); t.eq(err, "no_space")
  t.eq(rack.cells(), before)
  ok, err = E.put("jobs", "keep", H.blob(3000))
  t.eq(ok, nil); t.eq(err, "no_space")
  t.eq(E.get("jobs", "keep"), H.blob(300, 7))
  local E2 = H.boot(rack, { deviceMaxBytes = 1500 })
  t.eq(E2.list("jobs"), { "keep" })
end

function T.device_refusing_a_write_fails_cleanly()
  -- engine believes devices hold 4000 but they really hold 900: the write is refused by the device
  local rack = H.rack(2, 900)
  local E = H.boot(rack)
  t.ok(E.put("jobs", "keep", "old"))
  local ok, err = E.put("jobs", "keep", H.blob(1200))
  t.eq(ok, nil); t.eq(err, "io")
  t.eq(E.get("jobs", "keep"), "old")
  local E2 = H.boot(rack)
  t.eq(E2.get("jobs", "keep"), "old")
  t.eq(rack.cells(), 2)
end

-- Power loss after every possible number of device writes.
local function crashMatrix(prepare, action, check)
  local probe = H.rack(3)
  local E0 = H.boot(probe)
  prepare(E0)
  local w0 = probe.writes()
  action(E0)
  local total = probe.writes() - w0
  t.ok(total >= 3, "expected the action to take several writes, took " .. total)
  for n = 0, total do
    local rack = H.rack(3)
    local E = H.boot(rack)
    prepare(E)
    rack.power.writesLeft = n
    pcall(action, E)
    rack.power.writesLeft = math.huge
    local E2 = H.boot(rack) -- reboot
    check(E2, n)
    local E3 = H.boot(rack) -- and the answer is stable across another reboot
    check(E3, n)
    t.ok(E3.put("jobs", "after", "works")) -- still usable
    t.eq(E3.get("jobs", "after"), "works")
  end
end

function T.power_loss_during_overwrite_gives_old_or_new_never_a_mix()
  local old, new = H.blob(700, 1), H.blob(500, 2)
  local sawOld, sawNew = false, false
  crashMatrix(
    function(E) assert(E.put("jobs", "j", old)) end,
    function(E) E.put("jobs", "j", new) end,
    function(E, n)
      local v = E.get("jobs", "j")
      t.ok(v == old or v == new, "after " .. n .. " writes got neither old nor new")
      sawOld = sawOld or v == old
      sawNew = sawNew or v == new
    end)
  t.ok(sawOld and sawNew)
end

function T.power_loss_during_first_put_gives_nothing_or_all()
  local v1 = H.blob(700, 3)
  crashMatrix(
    function() end,
    function(E) E.put("jobs", "j", v1) end,
    function(E, n)
      local v, err = E.get("jobs", "j")
      t.ok(v == v1 or err == "not_found", "after " .. n .. " writes: " .. tostring(err))
    end)
end

function T.power_loss_during_delete_never_resurrects()
  local old = H.blob(700, 4)
  local firstGone
  crashMatrix(
    function(E) assert(E.put("jobs", "j", old)) end,
    function(E) E.delete("jobs", "j") end,
    function(E, n)
      local v, err = E.get("jobs", "j")
      t.ok(v == old or err == "not_found", "after " .. n .. " writes: " .. tostring(err))
      if err == "not_found" and not firstGone then firstGone = n end
      -- once a crash point shows "deleted", every later crash point must too
      if firstGone and n > firstGone then t.eq(err, "not_found", "resurrected at " .. n) end
    end)
  t.ok(firstGone)
end

function T.rebuild_cleans_leftovers()
  local rack = H.rack(3)
  local E = H.boot(rack)
  E.put("jobs", "j", H.blob(700, 1))
  rack.power.writesLeft = 2
  pcall(E.put, "jobs", "j", H.blob(700, 2))
  rack.power.writesLeft = math.huge
  rack.ctl[1].set((function() local d = rack.ctl[1].dump(); d.cjunk = "not a cell"; return d end)())
  local E2 = H.boot(rack)
  -- exactly one version remains (the interrupted one may have won with fewer copies), junk is gone
  local v = E2.get("jobs", "j")
  t.ok(v == H.blob(700, 1) or v == H.blob(700, 2))
  local versions = {}
  for _, ctl in ipairs(rack.ctl) do
    for id, cell in pairs(ctl.dump()) do
      t.ok(id ~= "cjunk", "junk entry survived")
      versions[cell:match("^[^|]+|(%d+)|")] = true
    end
  end
  local n = 0
  for _ in pairs(versions) do n = n + 1 end
  t.eq(n, 1)
end

function T.large_values_never_produce_a_string_minecraft_cannot_store()
  -- even if the config asks for huge shards (as the first release did), cells stay under 65535 bytes
  local rack = H.rack(3, 2000000)
  local E = H.boot(rack, { shardBytes = 200000, deviceMaxBytes = 1000000 })
  local big = H.blob(300000)
  t.ok(E.put("schematics", "big", big))
  t.eq(rack.power.crashed, nil)
  for _, ctl in ipairs(rack.ctl) do
    for _, cell in pairs(ctl.dump()) do t.ok(#cell <= 65000, "cell of " .. #cell .. " bytes") end
  end
  t.eq(E.get("schematics", "big"), big)
  t.ok(E.stat("schematics", "big").shards >= 7)
end

function T.yield_is_called_between_device_operations()
  local rack = H.rack(3)
  local engine = require("roles.storage.engine")
  local yields = 0
  local E = engine.new({ devices = rack.devs, crypto = require("lib.crypto"), replicas = 2, shardBytes = 300,
    deviceMaxBytes = 4000, clock = function() return 1 end, yield = function() yields = yields + 1 end })
  E.rebuild()
  local y0 = yields
  E.put("jobs", "j", H.blob(700))
  t.ok(yields - y0 >= 3)
end

return T
