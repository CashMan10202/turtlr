# BuildKit

A CC: Tweaked build service for Minecraft 1.21.1 (NeoForge). Players request a build on a locked
pocket computer; a locked turtle at their site finds materials, crafts what it needs and builds it.
All data and planning live on the owner's base computers.

Status: **Phase 1 of 10** (foundation). Nothing moves a turtle yet.

## Where things are

| Folder | What |
|---|---|
| `lib/` | Shared code: message packing (`codec`), message rules (`schema`, `proto`), `config`, `sha256` |
| `roles/<role>/` | One folder per kind of computer: its `config.lua` and README |
| `install/` | `install` (sets a computer up) and `verify` (checks the mods behave as expected) |
| `tools/` | Scripts you run on your own PC |
| `test/` | Tests that run outside Minecraft |
| `docs/` | Design, protocol reference, deploy guides |

## Start here

- What it is and why: `docs/superpowers/specs/2026-11-13-build-service-design.md`
- Deploy and test Phase 1 in-game: `docs/phase1-deploy.md`
- Every message and its allowed fields: `docs/protocol.md`

## Running the tests (on a PC)

```bash
lua5.2 test/run.lua
```

```bash
python3 -m unittest discover -s tools -p "test_*.py"
```
