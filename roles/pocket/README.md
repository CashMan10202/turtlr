# pocket

**Purpose:** The player's app: request builds, set turtle limits, follow progress.

**Hardware:** Advanced pocket computer with ender modem.

**Program:** `/bs/role/main.lua` (arrives in Phase 8). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install pocket` (see `docs/phase1-deploy.md`).
