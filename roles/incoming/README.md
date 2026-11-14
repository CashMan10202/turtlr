# incoming

**Purpose:** The only computer that hears players' devices. Decrypts, checks and forwards requests inward.

**Hardware:** Advanced computer, ender modem + wireless modem.

**Program:** `/bs/role/main.lua` (arrives in Phase 3). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install incoming` (see `docs/phase1-deploy.md`).
