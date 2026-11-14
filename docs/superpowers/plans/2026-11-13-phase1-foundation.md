# BuildKit Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested foundation: repo, test harness that runs outside Minecraft, strict message codec + schemas, config loader, hash-checked installer, in-game `verify` program, protocol spec and per-role configs.

**Architecture:** Pure Lua modules under `lib/` that never touch CC globals directly except through injected `fs`/`peripheral` tables, so they run under stock Lua 5.2 with a small CC shim. Installer and verify are thin CC front-ends over testable cores.

**Tech Stack:** Lua 5.2-compatible code (CC: Tweaked / Cobalt), `bit32`, Python 3 for `tools/`. Tests: `lua5.2 test/run.lua`.

**Spec:** `docs/superpowers/specs/2026-11-13-build-service-design.md`

## Global Constraints

- No `textutils.unserialise`/`load` on untrusted data. `load` is allowed only for owner-written config files, with an empty environment.
- Code must run on Lua 5.2 semantics: no integer division `//`, no `goto`-dependent tricks, no `string.pack`, no `utf8`. Use `bit32`.
- Modules return a table; no globals. `require` paths are relative to repo root (`lib.codec`), installed at `/bs/` on computers with `package.path` set by `startup.lua`.
- Channels: 4201 in, 4202 out, 4210 bus, 4211 telemetry. Protocol version 1.
- Limits (defaults): frame 2048 / max 8192 bytes; 3 active jobs; 20000 blocks per job; upload 262144 bytes; schematic quota 2097152 bytes; work area 48x48x64; scan radius 16.
- Every bug gets a failing test first. Only touch files a task names.
- Commits are local only and only if the owner has approved committing.

## Review Focus

1. Truncated or garbage frames into `codec.decode` -> returns `nil, err`, never throws, never loops. (Task 2)
2. Deeply nested / huge-length-prefix frames (memory bomb) -> rejected by depth 8 and declared-length-vs-remaining check before allocating. (Task 2)
3. Numbers that are NaN, infinite, fractional or out of range in integer fields -> schema rejects. (Task 3)
4. Installer interrupted mid-copy (reboot) -> old install still boots; no half-written file is ever at its final path. (Task 6)
5. `verify` run on a computer with a peripheral missing or with unexpected method names -> reports FAIL/SKIP for that row and continues; never crashes. (Task 7)

---

### Task 1: Test harness and CC shim

**Files:**
- Create: `test/run.lua`, `test/t.lua`, `test/cc_shim.lua`, `test/harness_test.lua`

**Interfaces:**
- Produces:
  - `t.eq(actual, expected, msg)`, `t.ok(v, msg)`, `t.err(fn, msg)` (deep equality for tables); each `*_test.lua` returns `{ name = function() ... end, ... }`.
  - `lua5.2 test/run.lua [pattern]` runs every `test/*_test.lua` (and `test/**/` one level), prints `PASS n / FAIL m`, exit code 1 on any failure.
  - `shim.new() -> env` with `env.fs` (in-memory: `open(path, mode)` r/w/a/rb/wb handles with `readAll/write/close`, `exists, isDir, makeDir, delete, move, list, getSize, getCapacity, getFreeSpace`), `env.os.epoch("utc")` (settable via `env.setTime(ms)`), `env.peripheral` (`env.attach(name, type, methodsTable)`; `getNames, getType, wrap, getMethods, find, call`), `env.capacity` default 1000000 (writes past it raise "Out of space").

- [ ] Step 1: write `test/harness_test.lua`: `t.eq({a={1,2}}, {a={1,2}})` passes; shim fs round-trip write/read; `fs.move` onto existing path errors; write past capacity errors; attached peripheral is found by type.
- [ ] Step 2: run `lua5.2 test/run.lua` -> fails (files missing).
- [ ] Step 3: implement `t.lua`, `run.lua` (use `io.popen("ls test")` to discover), `cc_shim.lua`.
- [ ] Step 4: run -> all pass.
- [ ] Step 5: commit (if approved).

### Task 2: Strict binary codec

**Files:**
- Create: `lib/codec.lua`, `test/codec_test.lua`

**Interfaces:**
- Produces: `codec.encode(value) -> string` (errors on unsupported type); `codec.decode(str, opts) -> value | nil, err` with `opts.maxDepth` (default 8), `opts.maxItems` (default 4096 total nodes).
- Wire format: tag byte then payload. `0x00` false, `0x01` true, `0x02` int (zig-zag varint, |n| <= 2^53), `0x03` string (varint len + bytes), `0x04` array (varint count + items), `0x05` map (varint count + (string key, value) pairs, keys sorted on encode), `0x06` float64 as 8 raw bytes is **not** supported — non-integer numbers are an encode error.
- Decode must consume the whole input (trailing bytes = error), reject duplicate map keys, reject counts/lengths larger than remaining bytes before allocating.

- [ ] Step 1: tests: round-trip of `{v=1, t="job.quote", a={1,-5,2^40}, m={x=true,y=false}, s=""}`; encode is deterministic regardless of key insertion order; `decode("")`, `decode("\255")`, every prefix of a valid frame, and valid frame .. "x" all return `nil, err`; array with declared count 2^30 and 1 byte left -> `nil`; depth 9 nesting -> `nil`; duplicate key -> `nil`; `encode(1.5)`, `encode(0/0)`, `encode(function() end)` raise; 2000 random byte strings (seeded) never throw.
- [ ] Step 2: run -> fail. Step 3: implement. Step 4: pass. Step 5: commit.

### Task 3: Schema validator and v1 message schemas

**Files:**
- Create: `lib/schema.lua`, `lib/proto.lua`, `test/schema_test.lua`, `test/proto_test.lua`

**Interfaces:**
- Consumes: `codec`.
- Produces:
  - `schema.check(spec, value) -> true | nil, "path: reason"`. Spec constructors: `S.int(min, max)`, `S.str(maxLen, pattern?)`, `S.bool()`, `S.enum{...}`, `S.id()` (namespaced ID `^[a-z0-9_.-]+:[a-z0-9_./-]+$`, max 96), `S.array(item, maxN)`, `S.map(fields, optionalFields?)` (unknown keys rejected), `S.bytes(maxLen)`.
  - `schema.clamp(limitsSpec, value, ownerMax) -> clampedTable` for turtle limits.
  - `proto.VERSION = 1`, `proto.CH = {IN=4201, OUT=4202, BUS=4210, TEL=4211}`, `proto.requests[type] = spec`, `proto.responses[type] = spec`, `proto.validate(msg) -> true | nil, err` (checks `msg.v == 1`, `msg.t` known, body matches), `proto.LIMITS` (defaults from Global Constraints), `proto.TURTLE_LIMITS` spec: `w,d (1..48)`, `up,down (0..64)`, `take ("all"|"marked"|"none")`, `mine (bool)`, `mineMax (0..4096)`, `chop (bool)`, `machines (bool)`, `me (bool)`, `fuelReserve (0..20000)`, `maxMinutes (1..1440)`, `keepOut` (array ≤8 of boxes `{x1,y1,z1,x2,y2,z2}` each −64..64).
  - All request types from spec section 6 defined with concrete fields (documented in Task 8's `docs/protocol.md`, generated from this table).

- [ ] Step 1: tests: valid `job.quote` passes; unknown field, unknown `t`, wrong `v`, int out of range, 2.5 in int field, `math.huge`, string over max, ID `"Minecraft:Stone"` and `"stone"` rejected; `clamp` lowers `w=999` to owner max 48 and fills missing with defaults; every entry in `proto.requests` has at least one valid sample in `test/proto_samples.lua` that validates and survives codec round-trip.
- [ ] Steps 2–5 as usual.

### Task 4: SHA-256

**Files:**
- Create: `lib/sha256.lua`, `test/sha256_test.lua`

**Interfaces:**
- Produces: `sha256.hex(str) -> 64-char lowercase hex`; `sha256.new() -> {update(self, str), finish(self) -> hex}` for streaming.
- Note: temporary home for hashing; Phase 3 may switch callers to vendored ccryptolib, keeping this interface.

- [ ] Step 1: tests: `""` -> `e3b0c442...b855`; `"abc"` -> `ba7816bf...15ad`; 1,000,000 x `"a"` streaming in 4096-byte updates -> `cdc76e5c...cc7112d0`; split-point independence (update in 1/55/56/64/65-byte pieces equals one-shot).
- [ ] Steps 2–5.

### Task 5: Config loader and role configs

**Files:**
- Create: `lib/config.lua`, `test/config_test.lua`, `roles/<role>/config.lua` for `storage, compute, incoming, outgoing, register, ingest, monitor, worker, pocket, gps`, `lib/config_specs.lua`

**Interfaces:**
- Consumes: `schema`.
- Produces: `config.load(fs, path, spec) -> cfg | nil, err` (reads file, `load(src, name, "t", {})`, must return a table, validated with `schema.check`, missing optional keys filled from `spec` defaults); `config.save(fs, path, cfg)` (write to `path..".tmp"`, then delete+move); `config_specs[role]` spec per role.
- Role config files contain only data (`return { ... }`) with a comment per key.

- [ ] Step 1: tests: loads valid file; file that calls `os.shutdown()` fails (empty env) without side effects; non-table return fails; out-of-range value fails naming the key; `save` then `load` round-trips; every shipped `roles/*/config.lua` loads cleanly against its spec.
- [ ] Steps 2–5.

### Task 6: Release manifest tool and installer

**Files:**
- Create: `tools/mkrelease.py`, `tools/test_mkrelease.py`, `install/installer_core.lua`, `install/install.lua`, `test/installer_test.lua`, `roles/_common/startup.lua`

**Interfaces:**
- Consumes: `sha256`, `config`.
- Produces:
  - `python3 tools/mkrelease.py --version X.Y.Z --out dist/` -> copies `lib/`, `roles/`, `install/` into `dist/` and writes `dist/manifest.lua`: `return { version="X.Y.Z", roles = { <role> = { {path="lib/codec.lua", dest="/bs/lib/codec.lua", size=N, sha256="..."}, ... } } }`. Every role gets all of `lib/` plus its own `roles/<role>/*` (mapped to `/bs/role/`), `roles/_common/startup.lua` -> `/startup.lua`.
  - `core.plan(manifest, role) -> entries | nil, err`
  - `core.fetchers.disk(fs, root)` and `core.fetchers.http(http, baseUrl)` -> `fetch(path) -> content | nil, err`
  - `core.install(fs, fetch, manifest, role, opts) -> true | nil, err`: for each entry fetch -> check size and sha256 -> write to `/bs/.staging/<dest>`; only when **all** verified: move each into place (delete old, move), write `/bs/.version` (`role`, `version`) last. Existing `/bs/role/config.lua` is never overwritten (new one saved as `config.lua.new`). Checks `fs.getFreeSpace` first.
  - `install.lua`: CC front-end: finds source (`/disk/buildservice/manifest.lua` or `http` URL arg), lists roles, asks for role, runs `core.install`, prints result.
  - `/startup.lua`: sets `package.path = "/bs/?.lua;/bs/?/init.lua;" .. package.path`, runs `/bs/role/main.lua` under `pcall`, on error logs to `/bs/crash.log` and reboots after 10 s (max 5 fast crashes, then halts with message).
- Not in this phase: signature on the manifest (Phase 3, needs Ed25519) and `.sig` files for CCSecureBoot.

- [ ] Step 1: tests (Lua, shim fs): happy path installs all files with right content and `.version`; tampered file content -> `nil, "hash mismatch: <path>"` and **no** file at any final path changed; unknown role -> error; second install keeps existing `config.lua` and writes `config.lua.new`; fetch fails on file 3 of 5 -> final paths untouched; insufficient free space -> error before any write; stale `/bs/.staging` from a previous crash is cleared at start.
- [ ] Step 1b: `tools/test_mkrelease.py` (unittest): manifest hashes match files; every role contains `lib/codec.lua`; output parses under `lua5.2` (`lua5.2 -e 'dofile("dist/manifest.lua")'`).
- [ ] Steps 2–5. Run: `lua5.2 test/run.lua installer && python3 -m unittest tools/test_mkrelease.py`.

### Task 7: In-game `verify` program

**Files:**
- Create: `install/verify_core.lua`, `install/verify.lua`, `test/verify_test.lua`

**Interfaces:**
- Produces: `core.checks` = ordered list of `{id, desc, run = function(env) -> "PASS"|"FAIL"|"SKIP", detail}`; `core.runAll(env) -> results` (each `run` under `pcall`; a throw = FAIL with the error text); `core.report(results) -> lines`. `verify.lua` passes real globals as `env`, prints with colours, writes `/verify_report.txt`.
- Checks (id: what PASS means):
  - `cc.version`: `_HOST` parses, CC >= 1.112
  - `fs.capacity`: prints capacity; PASS if >= 500000
  - `http`: `http` table exists
  - `gfx`: `term.setGraphicsMode` exists; with `--gfx` flag also switches to mode 1, draws, switches back
  - `nbt.type`: a peripheral of type `nbt_storage` or `nbtStorage` exists; detail = actual type + method list
  - `nbt.api`: has a read method and one of `writeTable|writeJson|save`
  - `nbt.size` (only with `--nbt-write`, refuses if the device already holds data): binary-search largest string payload accepted up to 1100000; detail = max
  - `geo.api`: `geoScanner`/`geo_scanner` found; has `scan`; detail = methods; with `--scan` runs `scan(16)` and reports block count and elapsed ms
  - `me.api`: ME Bridge found; detail = method list; PASS if it has an item-listing method (`listItems` or `getItems`) and a craft method (`craftItem`)
  - `pd.api`: Player Detector found; has `getPlayersInRange` and `getPlayerPos` or `getPlayer`
  - `modem`: at least one modem; detail = wireless yes/no per side
  - `gps`: `gps.locate(2)` returns coordinates
  - `turtle.equip`: on turtles, `turtle.equipLeft/Right` exist
  - `inv.generic`: on turtles, if a block in front has `list`, PASS and print item count
  - `secureboot`: `enroll-secure-boot` program resolves via `shell.resolveProgram` (detail says manual lock test still required)
- Missing hardware = SKIP, not FAIL.

- [ ] Step 1: tests with shim: no peripherals -> all hardware rows SKIP, none throw; fake `nbtStorage` with `read/writeTable` -> `nbt.type` and `nbt.api` PASS; fake with only `foo` -> `nbt.api` FAIL listing methods; fake nbt that rejects payloads > 1048576 -> `nbt.size` detail `1048576`; nbt holding data -> `nbt.size` SKIP "not empty"; a check whose peripheral method throws -> FAIL, later checks still run; `report` has one line per check.
- [ ] Steps 2–5.

### Task 8: Docs

**Files:**
- Create: `README.md`, `docs/protocol.md`, `docs/phase1-deploy.md`, `roles/<role>/README.md` (stub: purpose, hardware, config keys), `tools/gen_protocol_doc.lua`

**Interfaces:**
- `lua5.2 tools/gen_protocol_doc.lua > docs/protocol.md` renders frame layout (from spec section 6) plus a field table per message type from `proto.requests/responses`, so the doc cannot drift from code.
- `docs/phase1-deploy.md`: how to build a release on the owner's PC, get it onto a floppy or URL, run `install`, run `verify` with each flag, and what to send back (the `verify_report.txt` from: one base computer with nbt_storage, one turtle with Geo Scanner, one pocket).

- [ ] Step 1: test `test/docs_test.lua`: generated protocol doc mentions every key of `proto.requests`; each `roles/*/README.md` exists.
- [ ] Steps 2–5.

### Final check

- [ ] `lua5.2 test/run.lua` -> 0 failures; `python3 -m unittest discover tools` -> OK; `python3 tools/mkrelease.py --version 0.1.0 --out dist/` succeeds.
