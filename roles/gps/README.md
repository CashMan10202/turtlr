# gps

**Purpose:** Tells devices where they are. Needs four of these, high up and not all in one flat plane.

**Hardware:** Computer with ender modem.

**Program:** `/bs/role/main.lua` (arrives in Phase 5). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install gps` (see `docs/phase1-deploy.md`).
