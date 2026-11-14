-- One valid body per message type. Used by tests and by the protocol doc generator.
local hex64 = ("ab"):rep(32)
local lim = { w = 16, d = 16, up = 16, down = 4, take = "marked", mine = false, mineMax = 256, chop = false,
  machines = false, me = false, fuelReserve = 500, maxMinutes = 240, keepOut = { { -2, 0, -2, 2, 3, 2 } } }
local shape = { kind = "box", w = 5, h = 4, d = 5, block = "minecraft:stone_bricks", hollow = true }
local mats = { { id = "minecraft:stone_bricks", n = 64 } }

local requests = {
  ["hello"] = { client = "0.1.0", caps = 2 },
  ["shape.preview"] = { shape = shape },
  ["job.quote"] = { src = "shape", shape = shape },
  ["job.confirm"] = { job = "J1a2b3", quote = "Q9z" },
  ["job.cancel"] = { job = "J1a2b3" },
  ["job.list"] = { page = 0 },
  ["job.status"] = { job = "J1a2b3" },
  ["job.area"] = { job = "J1a2b3", limits = lim },
  ["job.plan"] = { job = "J1a2b3", page = 0 },
  ["job.approve"] = { job = "J1a2b3", plan = "P77" },
  ["lib.list"] = { page = 0 },
  ["lib.get_thumb"] = { ref = "L12" },
  ["acct.get"] = {},
  ["upload.begin"] = { name = "house.schem", size = 2048, sha = hex64, chunks = 2 },
  ["upload.chunk"] = { up = "U1", seq = 0, data = ("\0\255"):rep(512), sum = ("0f"):rep(8) },
  ["upload.end"] = { up = "U1" },
  ["import.link"] = { url = "https://example.com/house.schem" },
  ["import.status"] = { ref = "I5" },
  ["rekey"] = { sign = ("s"):rep(32), kx = ("k"):rep(32) },
  ["w.claim"] = { fuel = 1000, slots = 12 },
  ["w.survey"] = { job = "J1a2b3", seq = 0, last = true, pal = { "minecraft:chest", "minecraft:iron_ore" }, pts = { 1, 2, 3 } },
  ["w.inv"] = { job = "J1a2b3", x = 3, y = 0, z = -2, kind = "minecraft:chest",
    items = { { id = "minecraft:oak_planks", n = 64 } } },
  ["w.ops"] = { job = "J1a2b3", after = 0 },
  ["w.result"] = { job = "J1a2b3", seq = 4, ok = true },
  ["w.layer"] = { job = "J1a2b3", y = 0, part = 0 },
  ["w.progress"] = { job = "J1a2b3", stage = "build", placed = 10, fuel = 900, x = 1, y = 2, z = 3 },
  ["w.fault"] = { job = "J1a2b3", code = "blocked", x = 1, y = 2, z = 3 },
  ["w.done"] = { job = "J1a2b3", placed = 100 },
}

local responses = {
  ["hello"] = { server = "0.1.0", minClient = "0.1.0", time = 1700000000000, state = "ok" },
  ["shape.preview"] = { w = 5, h = 4, d = 5, count = 70, mats = mats },
  ["job.quote"] = { quote = "Q9z", count = 70, mats = mats, raw = mats, hand = 0, eta = 600, queue = 1,
    turtles = 1, expires = 1700000000000 },
  ["job.confirm"] = { job = "J1a2b3", state = "awaiting_turtle" },
  ["job.cancel"] = { job = "J1a2b3", state = "cancelled" },
  ["job.list"] = { jobs = { { job = "J1a2b3", state = "build", pct = 40, name = "Box 5x4x5" } }, more = false },
  ["job.status"] = { job = "J1a2b3", state = "build", pct = 40, eta = 300, placed = 28, total = 70, queue = 0,
    need = { { id = "minecraft:glass", n = 3 } } },
  ["job.area"] = { job = "J1a2b3", limits = lim },
  ["job.plan"] = { job = "J1a2b3", plan = "P77", page = 0, more = false, steps = {
    { k = "take", id = "minecraft:oak_planks", n = 64, x = 3, y = 0, z = -2 },
    { k = "supply", id = "minecraft:glass", n = 3 } } },
  ["job.approve"] = { job = "J1a2b3", state = "gather" },
  ["lib.list"] = { items = { { ref = "L12", name = "Small house", w = 7, h = 6, d = 9, count = 310, tested = true } },
    more = false },
  ["lib.get_thumb"] = { ref = "L12", w = 16, h = 12, data = ("\1"):rep(96) },
  ["acct.get"] = { name = "Steve", jobsActive = 1, jobsMax = 3, blocksMax = 20000, quotaUsed = 0,
    quotaMax = 2097152, devices = 2 },
  ["upload.begin"] = { up = "U1", next = 0 },
  ["upload.chunk"] = { up = "U1", next = 1 },
  ["upload.end"] = { ref = "I5" },
  ["import.link"] = { ref = "I5" },
  ["import.status"] = { ref = "I5", state = "ok", w = 7, h = 6, d = 9, count = 310, dropped = 2, hand = 14 },
  ["rekey"] = {},
  ["w.claim"] = { job = "J1a2b3", stage = "survey", limits = lim, scan = 16 },
  ["w.survey"] = { next = 1 },
  ["w.inv"] = {},
  ["w.ops"] = { done = false, limits = lim, ops = {
    { seq = 1, op = "goto", x = 3, y = 0, z = -1 },
    { seq = 2, op = "pull", id = "minecraft:oak_planks", n = 64, side = "front" } } },
  ["w.result"] = {},
  ["w.layer"] = { y = 0, part = 0, more = false, pal = { "minecraft:stone_bricks" }, cells = { 1, 2, 3 } },
  ["w.progress"] = { stop = false },
  ["w.fault"] = { act = "wait" },
  ["w.done"] = {},
}

return { requests = requests, responses = responses, limits = lim }
