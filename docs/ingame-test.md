# In-game setup and test (button version)

Everything is done from one setup screen with buttons. The **green button is always the next step**.
Click buttons with the mouse, or press the number shown on them. `q` goes back.

## Get the setup screen onto a computer

1. Open the computer's screen in Minecraft.
2. Drag `buildkit.lua` from your PC onto the Minecraft window.
3. Type:

```
buildkit
```

The setup screen opens. Later, on a computer that is already installed, just type:

```
setup
```

## What to build first

```
 [NBT] [NBT] [NBT]        each NBT Storage has a WIRED modem on it
   |     |     |          joined with networking cable
   +-----+-----+------ wired modem on computer A
                          [A: STORAGE]--[disk drive]--[B: COMPUTE]
                           wireless modem              wireless modem
```

Right-click every wired modem so its ring turns red. Put a blank floppy in the disk drive.

## Computer A (storage): press the green button each time

1. **Install a role** -> click **storage**
2. **Check this computer** -> **Check + NBT size** (only while the NBT Storage is still empty). Screenshot.
3. **Make new keys** -> mash the keyboard, press Enter
4. **Load keys (storage)**
5. **Reboot (start program)**

It should then say `Storage manager 1: 3 NBT Storage blocks. Running.`

## Computer B (compute)

1. **Install a role** -> click **compute**
2. **Load keys (compute)** (do NOT make new keys again)
3. **Test storage** -> you want eight green `[PASS]` lines. Screenshot.

## Turtle and pocket

Drag `buildkit.lua` on, type `buildkit`, then:

- Turtle (fuel, Geo Scanner equipped, chest in front): **Install a role** -> **worker**, then **Check this computer** -> **Check + area scan**
- Pocket: **Install a role** -> **pocket**, then **Check this computer** -> **Check + pixel test**

## Send me

Screenshots of the check on A, the storage test on B, and the turtle and pocket checks.

## If something goes wrong

| You see | Do this |
|---|---|
| `No such program` after dragging | Type `ls`. If `buildkit.lua` is not listed, the drag did not arrive: try again with the computer screen open |
| No "Make new keys" or "Load keys" button | No floppy found: put one in a disk drive touching this computer |
| "Load keys" missing but "Make new keys" shown on the 2nd computer | The floppy in the drive is not the one you made keys on |
| `no NBT Storage found` after reboot | A wired modem is not switched on (right-click it), or a cable is missing |
| `health ... timeout` in the storage test | Computer A is not running, or a wireless modem is missing |
| `put ... io` in the storage test | Screenshot the "Check + NBT size" result and send it to me |
| `Program crashed` | Run `edit /bs/crash.log` on that computer and screenshot it |
