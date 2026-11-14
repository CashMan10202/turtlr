# Phase 2: deploy and test in-game

Phase 2 gives you working storage: one or more STORAGE managers keeping data on your NBT Storage
farm, reachable only over the encrypted internal network.

## What you need in-game

- 1 advanced computer for STORAGE (2 for failover), each with a **wireless modem** and a **wired modem**
- 2 or more NBT Storage blocks, each with a wired modem on it, all cabled to the STORAGE computer(s).
  Right-click every wired modem so it turns red (connected).
- 1 advanced computer that will be COMPUTE, with a wireless modem (only used for the test for now)
- 1 floppy for the release, 1 floppy for keys (they can be the same floppy)

## Steps

1. **Build the release** on your PC and get it onto the floppy as in `docs/phase1-deploy.md`:

   ```bash
   python3 tools/mkrelease.py --version 0.2.0 --out dist/
   ```

2. **Install the roles.** On each STORAGE computer run `/disk/buildservice/install/install storage`,
   on COMPUTE run `/disk/buildservice/install/install compute`.

3. **Make the secret link keys, once.** On any one base computer, with the floppy in a drive:

   ```
   /bs/install/mkkeys
   ```

   Mash the keyboard when asked, then press Enter.

4. **Load keys on every base computer** (move the floppy to each):

   ```
   /bs/install/mkkeys load storage
   ```

   ```
   /bs/install/mkkeys load compute
   ```

   Afterwards keep the key floppy somewhere safe. Anyone holding it can talk to your base computers.

5. **Second storage manager only:** edit `/bs/role/config.lua` on it and set `id = 2`.

6. **Reboot the STORAGE computers.** Each should print `Storage manager 1: N NBT Storage blocks. Running.`
   The first one becomes "primary" about 6 seconds after starting.

7. **Run the test on COMPUTE:**

   ```
   /bs/install/storetest
   ```

   You should get eight green `[PASS]` lines. The times next to "put 100 KB" and "get 100 KB" tell us
   how fast your storage farm really is; please send me that output.

## Things to try

- **Reboot test:** run `storetest`, reboot the STORAGE computer, run it again. Data written before a
  reboot is still there (the test deletes its own keys, so check with the `health` line: key count stays).
- **Failover test (two managers):** shut down manager 1. Within about 10 seconds `storetest` works again,
  served by manager 2. Start manager 1 again and it takes over.
- **Damage test:** break one NBT Storage block and place it back empty. Within a scrub cycle
  (`scrubMinutes`, default 30) `storetest`'s health line shows `degraded 0` again.

## If something fails

| What you see | Meaning |
|---|---|
| `no NBT Storage found` | Wired modems not turned on (right-click them), or cable not connected |
| `/bs/keys.lua: missing` | Run `mkkeys load <role>` on that computer |
| `health ... timeout` | No storage manager is primary: is one running? same key floppy used for both computers? both have wireless modems? |
| `[FAIL] put ... io` | A device refused the write. Send me the Phase 1 `verify --nbt-write` report; the size limit or method name differs from what I assumed |
| `[FAIL] put ... no_space` | The farm is full, or `deviceMaxBytes` in the storage config is set too low |
| `Program crashed` then restart | See `/bs/crash.log` on that computer and send it to me |

## Settings worth knowing (`/bs/role/config.lua` on STORAGE)

| Key | Default | What it does |
|---|---|---|
| `id` | 1 | Manager number; lowest running id is primary |
| `replicas` | 2 | Copies of every piece of data, each on a different NBT Storage block |
| `shardBytes` | 200000 | Size of one piece |
| `deviceMaxBytes` | 1000000 | How much to put in one NBT Storage block; keep at or under `nbtStorageMaxSize` |
| `scrubMinutes` | 30 | Time for one full health check of the farm |
