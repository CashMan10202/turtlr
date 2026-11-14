# storage

**Purpose:** Keeps all data (jobs, players, schematics, recipes, logs) on the NBT Storage farm, with copies and integrity checks.

**Hardware:** Advanced computer, wired modem network to the NBT Storage blocks, wireless modem. Run at least two.

**Program:** `/bs/role/main.lua` (arrives in Phase 2). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install storage` (see `docs/phase1-deploy.md`).
