# register

**Purpose:** Where you enrol a player's pocket or turtle in person. Creates the device's key.

**Hardware:** Advanced computer, Player Detector, disk drive, wireless modem.

**Program:** `/bs/role/main.lua`. Deploy and test: `docs/phase3-deploy.md`.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install register` (see `docs/phase1-deploy.md`).
