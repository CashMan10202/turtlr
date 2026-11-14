# In-game test walkthrough (Phases 1 and 2)

Everything you type is in a code box. Type it on the computer's screen and press Enter.

## 0. Get the file

Download `buildkit.lua` (one file, about 320 KB) to your PC. It contains the whole release.

**Putting it on a computer:** open the computer's screen in Minecraft, then drag `buildkit.lua`
from your PC's file explorer onto the Minecraft window. The computer says it received the file.
Do this on each computer you set up (the file deletes itself after use to free space).

If dragging does not work on your server, tell me; the fallback is your friend uploading files
through Crafty (`docs/phase1-deploy.md`).

## 1. Build this

```
 [NBT] [NBT] [NBT]        each NBT Storage has a WIRED modem on it
   |     |     |          joined with networking cable
   +-----+-----+------ wired modem on computer A
                          [A: STORAGE]--[disk drive]--[B: COMPUTE]
                           wireless modem              wireless modem
```

- **A** and **B**: advanced computers. Put a wireless modem on each.
- **A** also gets a wired modem, cabled to a wired modem on each NBT Storage (start with 2 or 3, all empty).
- **Right-click every wired modem** so its ring turns red. This is the step people miss.
- Put one **disk drive touching both A and B**, with a blank floppy in it. Both computers can then use it.

## 2. Computer A (storage)

Drag `buildkit.lua` onto A, then:

```
buildkit storage
```

```
label set storage1
```

Check the mods (the NBT Storage must still be empty for this):

```
/bs/install/verify --nbt-write
```

Take a screenshot of the result. Then make the secret keys (mash the keyboard when asked, then Enter):

```
/bs/install/mkkeys
```

```
/bs/install/mkkeys load storage
```

```
reboot
```

A should now show: `Storage manager 1: 3 NBT Storage blocks. Running.` Leave it running.

## 3. Computer B (compute)

Drag `buildkit.lua` onto B, then:

```
buildkit compute
```

```
label set compute
```

```
/bs/install/mkkeys load compute
```

Wait about 10 seconds after A started, then:

```
/bs/install/storetest
```

You want eight green `[PASS]` lines. Screenshot it; the times on the two "100 KB" lines matter to me.

(If you reboot B it will say it cannot start `main.lua`. That is expected until Phase 4.)

## 4. Three quick experiments

1. **Reboot:** on A hold Ctrl+R to reboot it, wait 10 seconds, run `storetest` on B again. Still all green.
2. **Break a block:** break one NBT Storage and place it back (it comes back empty). Run `storetest`:
   still all green. The `health` line shows `degraded` above 0, and returns to 0 within 30 minutes.
3. **Turn A off:** hold Ctrl+S on A. `storetest` on B now fails with `timeout`. Turn A back on, wait
   10 seconds, and it passes again.

## 5. Turtle and pocket checks (Phase 1 leftovers)

**Turtle** (advanced turtle with some fuel, a Geo Scanner equipped, a chest in front of it). Drag `buildkit.lua` on, then:

```
buildkit worker
```

```
/bs/install/verify --scan
```

Watch whether the game stutters during the scan. Screenshot the result.

**Pocket computer** (advanced, ender modem). Drag `buildkit.lua` on, then:

```
buildkit pocket
```

```
/bs/install/verify --gfx
```

It should draw a short diagonal line of coloured dots and return to text. If the screen breaks, hold Ctrl+R.

## 6. Send me

- Screenshots of: `verify` on A, `storetest` on B, `verify` on the turtle, `verify` on the pocket.
- Whether the scan lagged the server.
- Anything that printed in red.

## If something goes wrong

| You see | Do this |
|---|---|
| `No such program` after dragging | Type `ls`. If `buildkit.lua` is not listed the drag did not arrive; try again with the computer screen open |
| `Install failed ... not enough free space` | The computer's disk is too small; tell me the number it printed |
| `no NBT Storage found` | A wired modem is not switched on (right-click it), or a cable is missing |
| `/bs/keys.lua: missing` | Run the `mkkeys load ...` line for that computer |
| `health ... timeout` in storetest | A is not running, or the two computers loaded keys from different floppies, or a wireless modem is missing |
| `put ... io` in storetest | The NBT Storage refused the write: send me the `verify --nbt-write` screenshot |
| `Program crashed` | On that computer run `edit /bs/crash.log` and screenshot it |
