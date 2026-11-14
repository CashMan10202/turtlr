-- COMPUTE config: limits, quotas and the maximums players can choose for their turtle.
return {
  limits = {
    jobsActive = 3,           -- jobs one player may have running at once
    jobBlocks = 20000,        -- biggest build, in blocks
    uploadBytes = 262144,     -- biggest uploaded schematic file
    schematicQuota = 2097152, -- stored schematic bytes per player
  },
  -- The most a player may allow their turtle. Players can only choose equal or lower on the pocket.
  turtleMax = {
    w = 48, d = 48, up = 64, down = 64, -- work area size
    take = "all",        -- "none", "marked" (only containers with the marker block on top) or "all"
    mine = true, mineMax = 4096,
    chop = true,
    machines = true,
    me = false,          -- attaching to ME networks is off until tested
    fuelReserve = 20000,
    maxMinutes = 1440,
    keepOut = {},
  },
  -- Block that marks a container as "the turtle may take from this" in "marked" mode (placed on top).
  marker = "minecraft:lime_wool",
  -- World areas no turtle may work in: { x1, y1, z1, x2, y2, z2 } in world coordinates.
  noBuild = {},
  -- Players who get a bigger share of the queue: { player = "Name", weight = 1..10 }.
  priorities = {},
  -- Blocks a turtle may dig out of its way. Everything else it goes around.
  replaceable = {
    "minecraft:short_grass", "minecraft:tall_grass", "minecraft:fern", "minecraft:large_fern",
    "minecraft:snow", "minecraft:water", "minecraft:lava", "minecraft:dead_bush", "minecraft:vine",
    "minecraft:dandelion", "minecraft:poppy",
  },
  -- Let turtles try to build their own small Create machines (experimental).
  level4 = false,
  -- How long (minutes) a quote stays valid.
  quoteMinutes = 15,
  -- Logging: level is "debug", "info", "warn" or "error"; keepKB is how much log to keep on this computer.
  log = { level = "info", keepKB = 64 },
  -- How often (seconds) this computer tells the monitor room it is alive.
  heartbeatSecs = 5,
}
