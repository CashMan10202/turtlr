# Storage recovery guide

How the data is kept: every value is cut into pieces, and each piece is written to `replicas`
different NBT Storage blocks. Every piece carries its own label (which value, which version, which
part, and a checksum). Because of that, **the NBT Storage blocks are the only thing that matters**:
any storage computer can be wiped or replaced and will rebuild its index by reading the blocks.

## A storage computer died or was broken

Place a new advanced computer, attach the modems, install the `storage` role, run
`mkkeys load storage`, set the same `id` in its config, reboot. It scans the farm and carries on.
Nothing is lost. With two managers, the other one takes over within about 10 seconds by itself.

## One NBT Storage block was broken or emptied

Nothing to do. Reads use the other copy at once, and the background scrub makes a new second copy
within one scrub cycle. `storetest` (or later the monitor room) shows `degraded` going back to 0.
Place a new block and cable it so there is room for the new copy.

## Several blocks lost at once

If both copies of a piece were on the lost blocks, that value is gone and is counted under `lost`.
Other values are unaffected. To make this unlikely: keep `replicas = 2` or raise it to 3, and avoid
breaking neighbouring blocks at the same time (pieces go to the emptiest blocks, which are often
the newest ones placed together).

## The farm is full (`no_space`)

Add NBT Storage blocks with wired modems, turn the modems on, reboot the storage manager(s).
New blocks are used immediately; a rebalance evens out the fill.

## Power cut / server crash in the middle of a write

Handled automatically. On start the manager keeps, for each value, the newest version that is
complete and removes leftovers. You get either the old value or the new one, never a mix.

## The index snapshot (`/bs/index.snap`)

Only a shortcut so start-up does not have to read every block. It is safe to delete at any time;
the manager rebuilds from the blocks. To keep an offline copy, copy that file to a floppy.

## Keys floppy lost or leaked

Run `mkkeys` again on a new floppy (type YES to replace) and `mkkeys load <role>` on every base
computer, then reboot them all. Old keys stop working at once. Stored data is not affected:
link keys protect the network, not the data on the blocks.

## Moving the farm

Stop the storage managers, move blocks with a tool that keeps block data (breaking an NBT Storage
block by hand loses its contents; test with one first), cable them up again, start the managers.

## What is NOT protected

- Someone with physical access to the NBT Storage blocks can read or wipe them (data on the blocks
  is checksummed, not encrypted).
- If two managers both act as primary for a few seconds (for example right as one starts), a write
  made in that moment can be lost; the scrub repairs copies but cannot recover an overwritten value.

## Known mod limit: 65535 bytes per text

Minecraft cannot save a single piece of text longer than 65535 bytes inside a block, and Advanced
Peripherals (seen on 0.8.2a) crashes the whole game when an NBT Storage is asked to hold one.
BuildKit 0.2.2 and later never write a piece larger than 60000 characters, and the storage adapter
refuses anything over 65000 before it reaches the block. If you write your own programs against
NBT Storage, keep every string under that size.
