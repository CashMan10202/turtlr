# monitor

**Purpose:** The control room: dashboards, player management, approvals, emergency stop.

**Hardware:** Advanced computer, wall of advanced monitors, optional speaker and redstone alarm, wireless modem.

**Program:** `/bs/role/main.lua` (arrives in Phase 9). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install monitor` (see `docs/phase1-deploy.md`).
