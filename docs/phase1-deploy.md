# Phase 1: deploy and test in-game

Phase 1 gives you the installer and the `verify` program. The goal is to learn how the mods on your
server really behave, so later phases are built on facts.

## 1. Build a release (on your PC)

You need Python 3. In the project folder:

```bash
python3 tools/mkrelease.py --version 0.1.0 --out dist/
```

This creates `dist/` with all files plus `manifest.lua` (the list of files and their hashes).

## 2. Get the release into the game

Pick one.

**A. Floppy disk, via Crafty (works with a private repo)**

1. In-game: put a floppy in a disk drive next to any computer and run `disk.getID("left")` in `lua`
   (use the side the drive is on). Note the number, for example `3`.
2. Ask your friend to upload the whole `dist` folder through Crafty's file manager to
   `world/computercraft/disk/3/` and rename it to `buildservice`
   (so `world/computercraft/disk/3/buildservice/manifest.lua` exists).
3. That floppy now carries the release. Move it to whichever computer you are installing.

**B. Web link**

Host the contents of `dist/` somewhere reachable by plain `https://` without a login
(a private GitHub repo will not work for this). Then on the computer:

```
wget https://YOUR-HOST/dist/install/install.lua install.lua
install <role> https://YOUR-HOST/dist/
```

## 3. Install

With the floppy in a drive next to the computer:

```
/disk/buildservice/install/install
```

Choose the role from the menu. Roles: `storage`, `compute`, `incoming`, `outgoing`, `register`,
`ingest`, `monitor`, `worker`, `pocket`, `gps`.

- If any file is damaged or changed, nothing is installed.
- Re-installing keeps your `/bs/role/config.lua`; the new default is saved next to it as `config.lua.new`.
- In Phase 1 the roles have no program yet, so after a reboot the computer says it cannot start
  `/bs/role/main.lua`. That is expected.

## 4. Run verify

Run it in three places and keep each `/verify_report.txt`.

**A base computer wired to one EMPTY NBT Storage (plus ME Bridge and Player Detector if you have them)**

```
/bs/install/verify --nbt-write
```

`--nbt-write` measures the real size limit by writing test data. Only use it on an empty NBT Storage.

**A turtle with a Geo Scanner equipped, a chest in front of it, and some fuel**

```
/bs/install/verify --scan
```

Watch for server lag during the scan. If it stutters badly, tell me; we lower the scan radius.

**A pocket computer (advanced, with ender modem)**

Pockets cannot use a disk drive, so use the web link install (2B), or ask your friend to copy
`dist/` into `world/computercraft/computer/<pocket id>/bs-release/` and run `/bs-release/install/install pocket`.

```
/bs/install/verify --gfx
```

`--gfx` draws a short diagonal line of coloured pixels, then returns to text. If the screen breaks,
hold Ctrl+R to reboot the pocket.

## 5. CCSecureBoot (by hand)

On a spare pocket and a spare turtle: run `enroll-secure-boot`, reboot, and check that
(a) you cannot reach a shell, (b) Ctrl+T does nothing, (c) it only boots a signed `startup.lua`.
Note whether the same key disk can sign files for more than one computer.

## 6. What to send back

- The three `verify_report.txt` files (copy the text).
- Whether the radius-16 scan lagged the server.
- What happened in the CCSecureBoot test.

## What each result means

| Line | If it fails |
|---|---|
| `cc.version` | CC: Tweaked is too old; needs 1.112+ |
| `fs.capacity` | Computer disk is under 500 KB; ask your friend to raise `computerSpaceLimit` |
| `http` | HTTP is off in `computercraft-server.toml`; only INGEST and web installs need it |
| `gfx` | CC: Graphics is not usable here; the pocket app will use the teletext renderer |
| `nbt.*` | The report lists the real method names; I adapt the storage code to them |
| `geo.api`, `me.api`, `pd.api` | Same: the report lists the real method names |
| `gps` | Fewer than 4 GPS hosts in range |
| `secureboot` | The mod's program was not found; locking falls back to "deterrent only" |
