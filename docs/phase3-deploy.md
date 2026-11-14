# Phase 3: gateways, registration and locked devices

After this phase a pocket (or turtle) can be registered at a desk in your base and then talks to
the base from anywhere, through the two gateway computers.

## What you need

| Computer | Extra parts |
|---|---|
| STORAGE and COMPUTE | already built in Phase 2 |
| INCOMING | **ender modem on TOP**, wireless modem on the BACK |
| OUTGOING | **ender modem on TOP**, wireless modem on the BACK |
| REGISTER (the desk) | wireless modem, a **Player Detector** touching it |
| a pocket | advanced pocket computer with an **ender modem** |

All base computers must be within wireless range of each other (about 60 blocks) and near the key floppy's disk drive when you load keys.

The modem sides matter on the two gateways: the computer cannot tell an ender modem from a normal one,
so it goes by side. If you prefer other sides, change `extSide` / `busSide` in `/bs/role/config.lua`.

## Steps

On every computer: get `buildkit.lua` (drag it on, or `wget`), then type `buildkit` and follow the green button.

1. **STORAGE and COMPUTE:** `Change role` -> same role as before (this updates them). Reboot both.
   COMPUTE now runs a real program and says `COMPUTE running.`
2. **INCOMING:** Install a role -> incoming, Load keys, Reboot. It says `INCOMING gateway running.`
3. **OUTGOING:** Install a role -> outgoing, Load keys, Reboot. It says `OUTGOING gateway running.`
4. **REGISTER:** Install a role -> register, Load keys, **Set owner name** (your exact Minecraft name), Reboot.
   It shows the registration desk menu.
5. **Pocket:** Install a role -> pocket, Reboot. It shows `Code: 123 456`.

Use the same key floppy as in Phase 2 (do not make new keys).

## Register the pocket

1. Stand at the desk holding the pocket (the pocket must be switched on and showing its code).
2. On the desk press `1`, type the code from the pocket, pick the player.
3. The desk shows a **check number**. The pocket shows `Check number:` too. They must be the same.
4. The pocket now shows `Server: connected (.. ms)`.

Walk far away (or to another dimension is NOT supported; same dimension only) and it stays connected.

## Things to try

- **Lock:** on the registered pocket hold Ctrl+T. Nothing should happen. Hold Ctrl+R: it reboots straight
  back into the app. Tell me if you find any way to reach a typing prompt.
- **Revoke:** desk menu `3`, pick the pocket. Within about a minute it shows `no answer`. Menu `4` brings it back.
- **Unlock:** desk menu `5`, pick the pocket. Within a few seconds it says `Unlocked by the owner` and gives a prompt.
- **A second player:** have a friend stand at the desk with their own pocket and register it for them.

## If something goes wrong

| You see | Meaning |
|---|---|
| `no ender modem on the top side` | Modem on the wrong side, or change `extSide` in the config |
| Desk: `set your Minecraft name as 'owner'` | Use **Set owner name** in `setup` |
| Desk: `no Player Detector attached` | Place it touching the desk computer |
| Desk: `The owner must stand at the desk` | You are too far from the Player Detector (default 3 blocks), or the owner name is spelled differently |
| Desk: `No device is showing that code` | The pocket is off, has no ender modem, or the code was mistyped |
| Desk: `incoming: timeout` / `outgoing: timeout` | That gateway is not running or has different keys |
| Desk: `The base did not answer` | COMPUTE or STORAGE is not running |
| Pocket stays on `Server: no answer (timeout)` | INCOMING or OUTGOING is down, or their ender modems are missing |
| Check numbers differ | Do not use that device: revoke it (menu `3`) and register again |

## What the lock does and does not do

It stops a player from stopping the app, getting a typing prompt, or booting the device from a floppy.
A device only locks after it has reached the base once, so a device that cannot connect is never stuck.
It does not stop someone with access to the server's files (Crafty) from reading the device's files,
and it does not need to: the base never trusts what a device says about itself.
