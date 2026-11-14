# Build Service ("BuildKit") — Design (rev 2)

Date: 2026-11-13. Status: awaiting approval. Target: CC: Tweaked on Minecraft 1.21.1 NeoForge.

Rev 2 change: the turtle is now **self-sufficient**. The owner supplies no materials.
The turtle finds, gathers, crafts and processes everything at the player's site, then builds.

## 1. Intent

A player uses a locked pocket computer to request a build (generated shape, library
design, or imported schematic) and is handed a locked turtle. They place it at their
site and give it a work area. The turtle surveys the area, reports what it found, and
the base works out a full plan: what to take from which storage, what to mine or chop,
what to craft, smelt or run through nearby machines. The turtle carries the plan out,
stockpiles everything in a chest, then builds. All data and calculation live in the
owner's base. No AI/LLM at runtime; everything is a fixed, schema-checked protocol and
a deterministic planner.

## 2. Goals, non-goals, anti-goals

Goals
- Thin, good-looking pocket client that holds no designs, recipes or server secrets.
- Turtle is a simple, crash-safe executor; the base is the brain.
- Signed + encrypted protocol, per-device keys, revocation, replay protection.
- Jobs never lost on reboot; turtles resume after chunk unload or crash.
- Recipes imported automatically, never typed by hand.
- Anything the turtle cannot make is listed clearly for the player to supply.
- Owner runs everything from a touch monitor wall.

Committed turtle scope (agreed)
- **Level 1:** find and take from storage in the area, craft, smelt, then build.
- **Level 2:** gather raw materials itself (mine, chop).
- **Level 3:** use machines that already exist nearby and hold items.
- **Level 4 (experimental, last, no promise):** build its own small Create machines from a few fixed, hand-tested layouts.

Non-goals
- Turtles travelling from the base; the owner providing materials; deposits/material balances.
- Reaching backpacks worn by players (only backpacks placed as blocks).
- Hiding client source perfectly (we deter with secure boot and make it not matter).
- Checking FTB Chunks claims (no peripheral exists; build-anywhere was chosen).
- Anything that needs software on the server machine (no host access).

Anti-goals
- A player-reachable machine holding a secret that unlocks other players or the base.
- A turtle touching blocks or containers outside its work area, or breaking non-resource blocks.
- A crafted schematic or link able to crash, stall or fill the base computers.

## 3. Constraints and facts

| Fact | Status | How to verify in-game |
|---|---|---|
| No access to the server machine; a friend edits files/config via Crafty Controller | owner | — |
| Python helpers run on the owner's PC only | follows | — |
| CC: Graphics adds `term.setGraphicsMode/setPixel/drawPixels/setFrozen`; pockets "might be unstable" | mod listing | on a pocket: `lua`, `term.setGraphicsMode(1)`, draw, `term.setGraphicsMode(0)` |
| CCSecureBoot: only signed files boot, no shell, no Ctrl+T, no disk boot | mod listing; **unverified on pocket/turtle** | enroll a test pocket and turtle, try to reach a shell |
| NBT Storage ~1,048,576 chars default (`nbtStorageMaxSize`); method names differ by version | AP config/docs | `peripheral.getMethods` on one |
| AP method names (Geo Scanner, ME Bridge, Player Detector) for 0.7.x | **unverified** | `peripheral.getMethods`; adapters probe at startup and stop with a clear message |
| Geo Scanner works as a turtle upgrade; scan radius ~8 default, costs fuel, has cooldown | **unverified numbers** | equip on turtle, `scan(8)`, check `cost(8)` |
| Turtle can read any adjacent block that exposes items (chests, placed backpacks, machines) via `list/pushItems/pullItems`, and `suck/drop` | CC:T generic peripherals | `peripheral.wrap("front").list()` facing each block type |
| Turtle joins an ME network by placing an ME Bridge against a cable | **unverified**; ME security may block | place bridge by cable, `listItems()` |
| Turtle swaps upgrades from inventory with `turtle.equipLeft/Right` | CC:T | swap pickaxe/crafting table |
| Ender modems reach any distance in one dimension (comms + base GPS) | CC:T | `gps locate` far from base |
| Computer disk 1 MB default | CC:T | `fs.getCapacity("/")` |

Phase 1 ships a `verify` program that tests every row and prints pass/fail.

## 4. Approaches considered

Delivery of turtles
- A. Fleet flies to the site — rejected by owner.
- **B. Handed-out locked turtles (chosen).**
- C. Both — rejected by owner.

Where materials come from
- Owner supplies kits — rejected by owner in rev 2.
- **Turtle sources everything on site (chosen)**, in the four levels above.

Where the thinking happens
- Smart turtle that plans locally — rejected by designer: turtle memory/disk is tiny, recipes would leave the base, updates need re-signing every turtle.
- **Base plans, turtle executes small "ops" (chosen):** turtle uploads what it sees; base returns a plan in small batches; turtle is a crash-safe interpreter.

## 5. Roles

| Role | Hardware | Program | Holds |
|---|---|---|---|
| STORAGE-n (2+) | adv. computer, wired modem to nbt_storage, wireless | `storaged` | link keys, index |
| COMPUTE | adv. computer, wireless | `computed` (jobs, scheduler, planner, recipe resolver, shapes, quotas) | link keys, device public keys |
| INCOMING | adv. computer, ender + wireless modem | `gate_in` | own X25519 secret, device public keys, link key |
| OUTGOING | adv. computer, ender + wireless modem | `gate_out` | own X25519 secret, device public keys, link key |
| REGISTER | adv. computer, Player Detector, disk drive, wireless | `registrar` (enrol pockets, provision turtles) | link key |
| INGEST | adv. computer, wireless, HTTP allowed | `ingestd` | link key only |
| MONITOR | adv. computer, monitor wall, speaker, redstone, wireless | `monitord` | link key, admin PIN hash |
| GPS x4 | computers with ender modems | `gps host` | nothing |
| WORKER turtle (handed out) | advanced turtle, secure boot, see section 9 | `worker` | own device key |
| POCKET (handed out) | adv. pocket, ender modem, secure boot | `client` | own device key |

Bare minimum: STORAGE-1 + 1 nbt_storage, COMPUTE, INCOMING, OUTGOING, REGISTER, 4 GPS, 1 worker turtle, 1 pocket.

```
                 (ender)                         (ender)
 POCKETS/WORKERS ~~~~~~> [INCOMING]      [OUTGOING] ~~~~~~> POCKETS/WORKERS
                            |  wireless, AEAD   ^
                            v                   |
   [REGISTER]--------->  [COMPUTE] -------------+-------> [MONITOR]==monitor wall
   PlayerDetector          |      \                         speaker/redstone
   disk drive              |       \--wireless--> [INGEST] --https--> allowlisted hosts
                           | wireless, AEAD
                           v
                    [STORAGE-1] [STORAGE-2] ...   (talk to each other)
                         |  wired modem network |
                 [nbt][nbt][nbt][nbt][nbt][nbt] ...  storage farm
   GPS hosts x4 (ender modems, high, not in one plane)
```

## 6. Protocol

Transport: raw `modem.transmit` (not rednet, so no rednet metadata is trusted).

| Channel | Use |
|---|---|
| 4201 | external: devices -> INCOMING |
| 4202 | external: OUTGOING -> devices |
| 4210 | internal bus |
| 4211 | internal heartbeat/telemetry to MONITOR |
| 65534 | GPS |

Crypto (library: **ccryptolib**, pure Lua, MIT; vendored and hash-pinned)
- Each device: Ed25519 signing key + X25519 key, generated on REGISTER, written to the device once; only public halves stay in the base.
- External frame: `ver | devId | counter | AEAD(ChaCha20-Poly1305, key = BLAKE3-derive(X25519(dev, edge)), nonce = counter, aad = header, body)`; `body = payload + Ed25519 signature`.
  - INCOMING: size check, known + not revoked, counter strictly increasing (persisted), timestamp ±120 s, decrypt, schema check, forward payload **with signature**. COMPUTE re-verifies, so a compromised INCOMING cannot forge requests.
  - OUTGOING encrypts each response to one device with its own key.
- Internal frame: AEAD with per-pair link key + counters. Link keys come from the owner's **master disk** at install; the disk is then stored away.
- Entropy: `random.initWithTiming()` plus owner key-mashing at REGISTER.
- Revocation: delete device public key from MONITOR. Rotation: signed `rekey`.

Encoding: small strict binary encoder (never `textutils.unserialise` on untrusted data). Every message type has a schema: fields, types, integer ranges, enums, max lengths; block and item IDs checked against whitelists. Unknown = reject.

Request types (v1)
- Pocket: `hello`, `shape.preview`, `job.quote`, `job.confirm`, `job.cancel`, `job.list`, `job.status`, `job.area` (set work area), `lib.list`, `lib.get_thumb`, `acct.get`, `upload.begin/chunk/end`, `import.link`, `import.status`, `rekey`.
- Worker: `w.claim`, `w.survey` (chunked scan results), `w.inv` (container contents), `w.ops` (fetch next op batch), `w.result` (op outcomes), `w.layer`, `w.progress`, `w.fault`, `w.done`.

Limits (config): 2 KB default / 8 KB max frame, 5 req/s burst + 60/min per pocket (workers get a higher survey budget), 3 active jobs and 20 000 blocks per job per player, 256 KB per upload, 2 MB schematic quota per player, work area max 48x48 wide and 64 tall.

## 7. Threat model

| Threat | Defence |
|---|---|
| Forged modem traffic | AEAD + Ed25519; unknown devId dropped after a size check |
| Replay | persisted counter + timestamp window |
| Oversized / flooding | frame cap, per-device + global token buckets |
| Stolen / modified pocket or turtle | per-device key; revoke on MONITOR |
| Player writes own client | needs a registered key; all requests schema-checked |
| Lying worker (fake survey/inventory) | only hurts that player's own job; plan ops are bounded and re-validated against the job |
| Compromised INCOMING | cannot sign; COMPUTE re-verifies |
| Compromised OUTGOING | cannot submit requests inward |
| Malicious schematic | parsed only on INGEST; caps; whitelist; block entities stripped |
| SSRF / bad links | https only, exact-host allowlist, no IP literals, redirects re-checked (max 2), size/time caps, plus server `http.rules` |
| Resource exhaustion | quotas; bounded queues; INGEST one job at a time with watchdog; planner has node and time budgets |
| **Turtle used to steal from other players** | work-area cap; owner no-go zones (GPS); the quote lists every container it will take from and the player must confirm; optional `marked_only` mode (only containers with a marker block on top); server claim protection is the real stop and the README says so |
| Turtle griefing | never leaves the work area; digs only (a) "replaceable" blocks, (b) resource blocks the plan names at exact positions; never digs containers, machines or anything else; emergency stop |
| Turtle kept | device key revoked; it stops working |

`http.rules` snippet for the friend to paste ships in Phase 6.

CCSecureBoot: enrolled on base computers, pockets and workers; one owner key disk signs releases. Device updates happen at REGISTER unless verification shows pre-signed over-the-air updates work.

## 8. Job pipeline

`request -> validate -> quote -> confirm -> awaiting_turtle -> survey -> plan -> confirm_plan -> gather -> process -> stockpile -> build -> done | failed | cancelled`

- **Quote** (before a turtle is on site): block counts, raw-material estimate from the recipe DB, unplaceable blocks, time estimate, queue position.
- **Plan** (after survey): exact sources — "take 64 oak planks from chest at +3,0,-2", "mine 12 iron ore", "smelt 12", "craft 3 hoppers", and a **"you must supply"** list. Player confirms on the pocket before anything is taken.
- Scheduler: weighted round-robin across players, config priorities and quotas. The scarce resources are turtles and COMPUTE planning time.
- Every state change is written to storage before it is acknowledged.
- Accounts hold quotas and history only (no material balances).

## 9. Worker turtle

Hardware: advanced turtle. Left side: ender modem (fixed). Right side: swapped as needed between diamond pickaxe, crafting table and Geo Scanner, carried in inventory. Starter items carried: stockpile chest, scratch chest (for clearing the crafting grid), furnace, optional ME Bridge, fuel.

Setup by player: place turtle, set work area on the pocket (box around the turtle), press Start.

Turtle program = small interpreter of **ops** with write-ahead state (state saved before each action, so reboot or chunk unload resumes exactly):
`goto, scan, inspect_inv, pull, push, dig_at, place_at, craft, smelt_start, smelt_collect, machine_put, machine_take, equip, refuel, wait, me_attach, me_take`

Stages
1. **Survey:** sweep the area in a grid with the Geo Scanner, upload block names + positions (compressed). Then visit each container/machine found and upload its contents.
2. **Plan:** base runs the resolver over: items found + things it can mine/chop + machines available. Returns op batches.
3. **Gather / process / stockpile:** execute ops; everything ends up in the stockpile chest beside the build origin.
4. **Build:** layer by layer, bottom-up, serpentine, placing below itself, restocking from the stockpile chest. Fetches one layer at a time.

Movement: dead-reckoning from the origin, GPS as a cross-check and for no-go zones. Pathfinding on the surveyed map (A* with a node cap), going around anything it may not dig.

Machine drivers (level 3): a data table mapping block ID -> how to feed and empty it and which recipe type it performs (furnace, blast furnace, smoker, stonecutter-equivalents, Create millstone / basin with an existing press or mixer / depot, Mekanism basics). Each driver is marked tested or untested; untested ones are off by default.

Level 4: a short list of fixed layouts (e.g. millstone + water wheel) stored in the library, tried only when enabled in config; failure falls back to "you must supply".

Placement classes for the build itself: `ok` (full cubes), `oriented` (logs, pillars, simple facing — best effort), `unreliable` (stairs, slabs, doors, Create shafts/cogs, pipes, machines, redstone parts) -> shown in the quote and left on a "finish by hand" list.

Multi-turtle: the build is split into vertical strips, one per turtle; one turtle is the gatherer/crafter, the rest wait then build. Single turtle does everything in sequence.

Turtle limits (set by the player on the pocket, "Turtle Limits" screen, one slider/toggle per line;
each is clamped server-side to the owner's maximum in config, and stored per job):
work-area size (width/depth/up/down), take mode (all containers / marked only / none),
allow mining (on/off) and max blocks mined, allow tree chopping, allow using machines,
allow ME access, min fuel reserve, max run time, keep-out boxes inside the area.
The server sends the limits with every op batch and the turtle also enforces the area and dig limits itself.

Running out mid-build: turtle waits, job shows what is missing; continues when the stockpile chest has it.

## 10. Storage layer

- Records text-safe encoded, split into ≤200 KB shards, each on 2 different nbt_storage devices; BLAKE3 checksum per shard.
- Index + write-ahead journal on each STORAGE computer, mirrored to nbt_storage.
- Atomic write: write shards -> verify -> flip index -> commit. Half-writes cleaned on boot.
- Scrub, repair, rebalance, per-device health, index snapshots to floppy.
- API: `put/get/delete/list/stat`; namespaces `players/ jobs/ schematics/ recipes/ library/ surveys/ logs/ config/`.

Internal schematic format (BSF): header, palette, run-length block data in 16-layer slabs.

## 11. Ingest

- Link (main path on locked pockets): INGEST fetches under the rules in section 7.
- Upload: chunked, hashed, resumable; files get onto a pocket via the REGISTER disk drive.
- Pure-Lua parsing on INGEST: gzip + NBT for Create `.nbt`, Sponge `.schem`, legacy `.schematic`, `.litematic`. Caps: 256 KB compressed, 4 MB inflated, 64x64x64, yields + watchdog.
- Optional: owner pre-converts large files on their PC with `tools/schem2bsf.py`.
- Report to the player: understood / dropped / can't place / materials / time. Library submissions wait for approval on MONITOR.

## 12. Recipes and planner

- `tools/export_recipes.py` (owner's PC): reads recipe JSONs + tags from mod jars and datapacks, writes a compact DB, brought in through INGEST.
- Resolver: dependency tree, cycle detection, alternatives ranked by what is on site, tags expanded, budgets on nodes and time.
- Recipe types map to capabilities: `crafting` (turtle), `smelting` (carried furnace), others need a matching machine driver present in the survey, else "you must supply".
- Raw-material table: which blocks give which items when mined (from loot tables where simple, otherwise a small built-in table).
- Library designs carry a tested flag; the owner's benchmark tool measures items/hour through an ME Bridge.

## 13. Pocket app

Renderers picked at launch: graphics mode (CC: Graphics) -> teletext sub-pixels -> plain text. One UI toolkit: cards, buttons, tab bar, status bar, paging, short transitions, dark/light themes.
Screens: Home, New Build, Library, Import, My Jobs (with live stage, "you must supply" list, plan confirm, work-area setup), Quote & Confirm, Account, Settings, About.

## 14. Monitor room

Touch UI, industrial look, green/amber/red. Dashboards (jobs, turtles with stage/position/fuel, computers, storage, traffic, ingest, alerts), file browser + small-file editor, log viewer, player and device management, library approvals, config editor with validation, emergency stop, maintenance mode, speaker/redstone alarms, optional overview monitor.

## 15. Repo layout

```
buildservice/
  lib/        proto, codec, crypto (wraps vendored ccryptolib), bus, log, config, storeclient, ui/
  roles/      storage/ compute/ incoming/ outgoing/ register/ ingest/ monitor/ worker/ pocket/ gps/
              (each: startup.lua, main program, config.lua, README.md)
  tools/      export_recipes.py, schem2bsf.py, mkrelease.py
  test/       protocol simulator, fake world + fake turtle, fake ME Bridge, fake nbt_storage
              (runs under plain Lua outside Minecraft)
  install/    install.lua, verify.lua
  docs/
```

Tests are written before each module and run outside Minecraft against the fakes.

## 16. Delivery phases

1. Repo, configs, installer, `verify`, protocol spec.
2. Storage layer + shared libraries.
3. INCOMING/OUTGOING + REGISTER + signed protocol.
4. Jobs, scheduler, quotes, quotas.
5. Worker core: op interpreter, movement, resume, building from a stockpile chest; then multi-turtle.
6. Ingest + library.
7. Recipe export + resolver + planner; worker Level 1, then 2, then 3; Level 4 as a separate experimental step.
8. Pocket app.
9. Monitor room.
10. Test tools, hardening review, setup guide.

After Phase 5 the turtle can already build if the player fills the stockpile chest by hand; Phase 7 makes it self-sufficient.

## 17. Calls made by the designer — please check

- Base plans, turtle executes ops.
- Raw modem channels instead of rednet; ccryptolib.
- Added REGISTER; removed kit bay, deposits and base resource turtles.
- Turtle hardware: ender modem fixed, other side swapped between pickaxe / crafting table / Geo Scanner.
- Player confirms the sourcing plan before the turtle takes anything; optional `marked_only` mode.
- Work area capped at 48x48x64; other limits in section 6 and 11.
- Dead-reckoning from placement, GPS as a check.
- Digging limited to replaceable blocks and plan-named resource blocks.
- Machine drivers ship "untested = off".
- Device updates at REGISTER unless over-the-air signed updates verify.
