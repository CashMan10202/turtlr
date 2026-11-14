# BuildKit Phase 2 (Storage + shared libraries) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A crash-safe, replicated key/value store on NBT Storage blocks, served over an encrypted internal bus, plus the shared libraries every later phase uses (crypto wrapper, log, bus, rpc, store client).

**Architecture:** Every piece of data ("cell") written to an NBT Storage block describes itself (key, version, part number, hash), so the index can always be rebuilt by scanning the blocks; the on-disk index is only a cache. A new version is written completely before the old one is removed, which makes writes atomic. One storage manager is primary at a time; others stand by and take over.

**Tech Stack:** Lua 5.2 semantics, vendored ccryptolib (commit 14489aa), tests under `lua5.2 test/run.lua`.

**Spec:** `docs/superpowers/specs/2026-11-13-build-service-design.md` (sections 6, 7, 10)

## Global Constraints

- All Phase 1 constraints still apply.
- NBT Storage content uses only string keys and string values (no booleans, numbers or lists), because the Lua<->NBT conversion of other types is unverified.
- Stored data is base64 text. Keys match `^[A-Za-z0-9_.:-]+$`, namespaces are one of `players jobs schematics recipes library surveys logs config`.
- Defaults: replicas 2, shardBytes 200000, deviceMaxBytes 1000000, bus payload max 65536 bytes, transport part 32768 bytes, value max 4194304 bytes.
- Bus replay rule: counter = (ms since 1970) * 4096 + sequence; a receiver accepts a frame only if its counter is higher than the last from that sender and its time part is within 120 s of the receiver's clock.
- No engine operation may run longer than one device read/write without calling `yield`.

## Review Focus

1. Power loss between any two device writes during put/overwrite/delete -> after `rebuild` the key holds either the complete old value or the complete new value, never a mix, never a resurrected deleted value. (Task 6)
2. A device returns garbage, an empty table, or throws -> that replica is skipped and counted, the read succeeds from another replica. (Tasks 5, 6)
3. All devices full -> put fails cleanly with `no_space`, old value intact, no stray cells. (Task 6)
4. Replayed, reordered, truncated or wrong-key bus frames -> dropped, never delivered. (Task 3)
5. Two managers both believing they are primary -> the higher id steps down on hearing the lower id. (Task 8)

---

### Task 1: Crypto wrapper, base64, vendored library in releases

**Files:** Create `vendor/ccryptolib/*` (copied), `lib/crypto.lua`, `lib/base64.lua`, `test/crypto_test.lua`, `test/base64_test.lua`, `test/cc/expect.lua`; Modify `tools/mkrelease.py`, `tools/test_mkrelease.py`, `test/run.lua` (package.path adds `./vendor/?.lua;./test/?.lua`, defines `os.epoch`, `os.day` if missing).

**Interfaces — Produces:**
- `crypto.init(seed)` (seed string >= 32 bytes; must be called once before anything random), `crypto.random(n) -> bytes`
- `crypto.hash(data) -> 32 bytes` (BLAKE3), `crypto.hex(bytes) -> hex`, `crypto.hashHex(data) -> 64 hex`
- `crypto.kdf(context, material) -> 32 bytes`
- `crypto.seal(key32, counter, plaintext, aad) -> sealed` (ciphertext .. 16-byte tag), `crypto.open(key32, counter, sealed, aad) -> plaintext | nil`; nonce = counter as 12 bytes little-endian (counter < 2^53)
- `base64.encode(bytes) -> text`, `base64.decode(text) -> bytes | nil`
- mkrelease: every role also gets `vendor/ccryptolib/**.lua` at `/bs/ccryptolib/...`

- [ ] Tests: seal/open round trip; any flipped bit in sealed, wrong aad, wrong counter, wrong key, sealed shorter than 16 -> `nil`; hashHex("abc") = `6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85`; kdf differs by context; random before init errors; base64 RFC 4648 vectors (`""`, `f`→`Zg==`, `foobar`→`Zm9vYmFy`), all 256 byte values round trip, invalid text -> nil; release contains `/bs/ccryptolib/aead.lua`.
- [ ] Red, implement, green, commit.

### Task 2: Log

**Files:** Create `lib/log.lua`, `test/log_test.lua`

**Interfaces — Produces:** `log.new{ fs, path, level, keepKB, clock, sink? } -> L`; `L.debug/info/warn/error(tag, msg, fields?)` (fields: flat table of string/number/boolean); line format `<ms> <LEVEL> <tag> <msg> k=v ...` (newlines in values replaced by space); when file exceeds keepKB it is moved to `path..".1"` (replacing it); `L.tail(n) -> lines`; `sink(entry)` called with `{ts, level, tag, msg, fields}` under pcall; write failures (disk full) never throw.

- [ ] Tests: level filter; rotation keeps total <= 2*keepKB; disk-full does not throw; sink error does not throw; tail returns last n across rotation boundary only from current file.

### Task 3: Bus

**Files:** Create `lib/bus.lua`, `test/fake_net.lua`, `test/bus_test.lua`

**Interfaces — Produces:**
- `fake_net.new() -> net`; `net.modem(name) -> modem` (`open, close, isOpen, transmit(ch, reply, payload)`); `net.deliver() -> list of {to=modemName, ch, reply, payload}` queued for every other modem with that channel open; `net.tap(fn)` to observe/alter frames.
- `bus.new{ modem, channel, role, instance, keys, crypto, clock } -> B` (`keys[peerRole] = key32`; own role key used for same-role peers)
- `B.send(dst, msg) -> true | nil, err` (msg = codec-encodable table; errors: `no_key`, `too_big`)
- `B.receive(channel, payload) -> { src, instance, msg } | nil, reason` (reasons: `not_for_me`, `no_key`, `bad_frame`, `bad_auth`, `replay`, `stale`); `dst` may be own role or `"*"`
- Frame = `codec.encode{ s, i, d, c, p }`, `p = crypto.seal(key, c, codec.encode(msg), s.."|"..i.."|"..d)`.

- [ ] Tests: round trip; frame for another role -> `not_for_me`; unknown sender -> `no_key`; tampered byte -> `bad_auth` or `bad_frame`; same frame twice -> `replay`; older frame after newer -> `replay`; frame with time part 10 min old -> `stale`; two instances of one role tracked separately; payload over 65536 -> `too_big`; garbage strings never throw; broadcast `"*"` received by all key holders.

### Task 4: RPC

**Files:** Create `lib/rpc.lua`, `test/rpc_test.lua`

**Interfaces — Produces:**
- `rpc.new{ bus, channel, pull, startTimer, clock } -> R` (`pull(filter?) -> event...` like `os.pullEvent`)
- `R.call(dst, method, body, timeoutSecs?) -> body | nil, err` (default 5 s; err `timeout` or the server's error code string); request msg `{ k="q", id, m=method, b=body }`, reply `{ k="r", id, ok=1|0, b?, e? }`
- `R.serveOnce(handlers, event...) -> handled` processes one `modem_message` event: runs `handlers[m](body, src, instance) -> body | nil, errcode` under pcall (throw -> `internal`), replies to sender role.
- `R.notify(dst, method, body)` (no reply expected, `k="n"`; delivered to `handlers[m]`)

- [ ] Tests with fake_net and a scripted event queue: call/serve round trip; unknown method -> `no_method`; handler throw -> `internal`; no server -> `timeout` after timer event; reply with wrong id ignored; notify reaches handler and sends no reply.

### Task 5: Device adapter

**Files:** Create `roles/storage/device.lua`, `test/fake_nbt.lua`, `test/device_test.lua`

**Interfaces — Produces:**
- `fake_nbt.new{ limit=1048576, style="writeTable"|"writeJson"|"save" } -> periph, ctl` (`ctl.corrupt(key)`, `ctl.fail(n)` next n calls throw, `ctl.wipe()`, `ctl.writes` counter, `ctl.dump()`); stores a deep copy; rejects when total string length > limit.
- `device.wrap(name, periph, methodNames) -> D | nil, err`; `D.name`; `D.load() -> cells | nil, err` (table string->string; non-string entries dropped and counted in `D.junk`); `D.store(cells) -> true | nil, err`; `D.errors` (count of failed calls).
- `device.discover(peripheral) -> list of D` for types `nbtStorage`/`nbt_storage`, sorted by name.

- [ ] Tests: load/store round trip in all three styles; over-limit store -> nil,err and old content intact; throwing peripheral -> nil,err, errors incremented, never throws; non-table read -> treated as empty with junk count; discover finds both type names.

### Task 6: Storage engine core

**Files:** Create `roles/storage/engine.lua`, `test/engine_test.lua`

**Interfaces — Consumes:** `device`, `crypto`, `base64`. **Produces:**
- `engine.new{ devices, crypto, replicas, shardBytes, deviceMaxBytes, yield?, clock } -> E`
- `E.rebuild() -> stats` (scan all devices, rebuild index, drop incomplete versions and superseded cells)
- `E.put(ns, key, value) -> true | nil, err` (`bad_key`, `too_big`, `no_space`, `io`)
- `E.get(ns, key) -> value | nil, err` (`not_found`, `corrupt`)
- `E.delete(ns, key) -> true | nil, err`
- `E.list(ns, prefix?, after?, limit?) -> keys, more`; `E.stat(ns, key) -> { size, ver, shards, time } | nil`
- Cell: device entry `c<16 hex>` = `"<ns/key>|<ver>|<i>|<n>|<size>|<hash hex>|<flag>\n<base64>"`, flag `d` data or `x` tombstone.
- Rules: shard copies go to `replicas` distinct devices with the most free space (fewer devices than replicas -> use all); new version fully written and read back before old cells are removed; delete writes tombstones (ver+1) to `replicas` devices before removing data cells; rebuild picks, per key, the highest version that is complete (all shards have >=1 valid copy) and treats a tombstone as complete.

- [ ] Tests: put/get small and 3-shard values; binary-safe (all byte values); overwrite returns new; delete then get `not_found`; list with prefix/after/limit sorted; rebuild on a fresh engine over the same devices reproduces every key; **crash matrix**: for n = 1..(writes in an overwrite), stop after n device writes (fake throws thereafter), build a fresh engine, rebuild -> value is old or new exactly; same for delete (old or not_found, and stays that way after a second rebuild); one replica corrupted -> get still returns value; all replicas of a shard corrupted -> `corrupt`; devices full -> `no_space` and old value intact and no cells of the failed version left after rebuild; bad key/namespace -> `bad_key`; replicas 2 with a single device works.

### Task 7: Scrub, repair, rebalance, health, cache, snapshot

**Files:** Modify `roles/storage/engine.lua`; Create `test/engine_maint_test.lua`

**Interfaces — Produces:**
- `E.scrubStep() -> report` (checks one device per call, round-robin: verifies every cell's hash, removes bad cells, then repairs any shard with fewer than `replicas` good copies by copying to another device); `report = { device, checked, bad, repaired, lost }`
- `E.rebalance(maxMoves?) -> moved` (moves cells from the fullest to the emptiest device while fill differs by > 30 %)
- `E.health() -> { devices = { {name, used, cells, errors, ok} }, keys, bytes, capacity, degraded, lost }`
- `E.addDevice(D)`, `E.removeDevice(name) -> true | nil, err` (drains its cells elsewhere first)
- hot cache: `engine.new{ ..., hot = { jobs=true, players=true, config=true }, cacheBytes = 262144 }`; gets of hot namespaces are served from memory (LRU by bytes), invalidated on put/delete.
- `E.snapshot() -> string` (index as text), `E.loadSnapshot(str) -> true | nil` (used as boot cache; verified lazily, any miss triggers `rebuild`).

- [ ] Tests: corrupt one replica -> after scrubbing all devices, both replicas valid again; wipe a whole device -> scrub restores replica count; all copies gone -> counted in `lost`, get `corrupt`; rebalance evens fill and all values still readable; removeDevice keeps all values; cache serves second get with zero device reads and is invalidated by put; snapshot/loadSnapshot round trip; loadSnapshot with garbage -> nil.

### Task 8: Storage server, election, store client

**Files:** Create `roles/storage/server.lua`, `roles/storage/main.lua`, `lib/storeclient.lua`, `test/storage_integration_test.lua`

**Interfaces — Produces:**
- `server.new{ engine, rpc, id, clock, log } -> S`; `S.handlers` (rpc methods `put, put_part, get, get_part, delete, list, stat, health`); `S.tick()` (election + one scrub step when primary); `S.isPrimary()`.
- Election: every 2 s each manager notifies `hb { id, primary }` to role `storage`; a manager is primary iff it has heard no lower id for 6 s; on becoming primary it runs `rebuild`. Non-primaries answer every request with error `not_primary`.
- Multipart: values over 32768 bytes go as `put_part { ns, key, up, i, n, d }` (server buffers up to 4194304 bytes per upload, 60 s idle timeout, 4 uploads at once) and `get_part { ns, key, i } -> { n, d, ver }` (client restarts if `ver` changes).
- `storeclient.new{ rpc, retries=3 } -> C`; `C.put(ns, key, value)`, `C.get(ns, key)`, `C.delete(ns, key)`, `C.list(ns, prefix, after, limit)`, `C.stat(ns, key)`, `C.health()`; plus `C.putTable/getTable` (codec-encoded tables). Retries on `timeout`/`not_primary`.
- `roles/storage/main.lua`: loads config + `/bs/keys.lua`, discovers devices, opens the wireless modem, runs `parallel`: rpc serve loop, tick timer, heartbeat to MONITOR channel.

- [ ] Tests (two servers + one client on fake_net, shared fake devices, scripted event pump): put/get 100 KB value through multipart; lower id is primary, higher answers `not_primary`; kill primary -> after 6 s the other takes over and returns previously stored values; both primary -> higher steps down after hearing lower; upload abandoned midway is discarded after 60 s; client retries through a failover.

### Task 9: Keys tool and docs

**Files:** Create `install/mkkeys.lua`, `install/keys_core.lua`, `test/keys_test.lua`, `docs/phase2-deploy.md`, `docs/recovery.md`; Modify `roles/storage/README.md`, `README.md`

**Interfaces — Produces:**
- `keys_core.generate(random, roles) -> { [role] = { [peer] = key32 } }` (symmetric: `t[a][b] == t[b][a]`, plus `t[a][a]`); `keys_core.serialise(roleKeys) -> lua source` (hex strings), `keys_core.load(fs, path) -> keys | nil, err` (binary keys).
- `mkkeys` (in-game, floppy in drive): seeds randomness from timing + typed keystrokes, writes `/disk/bskeys/<role>.lua` for each role; `mkkeys load <role>` copies that role's file to `/bs/keys.lua` on the current computer.
- Docs: deploy/test steps for Phase 2; recovery procedure (lost computer, lost device, lost index, full farm, restoring from snapshot).

- [ ] Tests: generate is symmetric and all keys distinct and 32 bytes; serialise -> load round trip; load rejects wrong-length or non-hex keys.

### Final check

- [ ] `lua5.2 test/run.lua` 0 failures; `python3 -m unittest discover -s tools -p 'test_*.py'` OK; release builds.
