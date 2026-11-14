# ingest

**Purpose:** The only computer allowed to download or parse schematics. Isolated from everything else.

**Hardware:** Advanced computer, wireless modem. HTTP must be allowed for it.

**Program:** `/bs/role/main.lua` (arrives in Phase 6). In Phase 1 this role only has its config.

**Config:** `/bs/role/config.lua`. Each key is explained by a comment in the file; allowed ranges are in
`lib/config_specs.lua`. A bad value stops the program at start with a message naming the key.

**Install:** `/disk/buildservice/install/install ingest` (see `docs/phase1-deploy.md`).
