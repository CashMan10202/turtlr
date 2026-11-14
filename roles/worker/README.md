# worker

**Purpose:** The turtle handed to a player. Surveys the area, gathers, crafts and builds, following steps sent by the base.

**Hardware:** Advanced turtle, ender modem; carries a diamond pickaxe, crafting table and Geo Scanner to swap between.

**Program:** `/bs/role/main.lua`. Deploy and test: `docs/phase3-deploy.md`.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install worker` (see `docs/phase1-deploy.md`).
