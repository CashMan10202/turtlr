-- Device lock for pockets and turtles handed to players.
-- While /bs/.locked exists, /startup.lua (see roles/_common/startup.lua):
--   * ignores Ctrl+T, so the app cannot be stopped,
--   * reboots after a crash instead of dropping to a typing prompt,
-- and booting from a floppy next to the device is switched off.
-- The owner releases a device from the REGISTER computer; the device learns it on its next hello.
local lock = {}

lock.MARKER = "/bs/.locked"

function lock.isLocked(fs) return fs.exists(lock.MARKER) end

function lock.engage(fs, settings)
  local h = fs.open(lock.MARKER, "w")
  h.write("1")
  h.close()
  settings.set("shell.allow_disk_startup", false)
  settings.save()
end

function lock.release(fs, settings)
  if fs.exists(lock.MARKER) then fs.delete(lock.MARKER) end
  settings.set("shell.allow_disk_startup", true)
  settings.save()
end

return lock
