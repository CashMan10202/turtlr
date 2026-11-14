#!/usr/bin/env python3
"""Builds a BuildKit release folder: the files to copy onto a floppy or web host, plus manifest.lua.

    python3 tools/mkrelease.py --version 0.1.0 --out dist/

manifest.lua lists, per computer role, every file with its size and SHA-256 hash.
The in-game installer refuses any file that does not match.
"""
import argparse, hashlib, os, re, shutil, sys

MARKER = ".buildkit-release"


def lua_files(root, sub):
    """Relative paths (forward slashes) of all .lua files under root/sub, sorted."""
    found = []
    for folder, _dirs, files in os.walk(os.path.join(root, sub)):
        for name in files:
            if name.endswith(".lua"):
                rel = os.path.relpath(os.path.join(folder, name), root)
                found.append(rel.replace(os.sep, "/"))
    return sorted(found)


def build(root, out, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit("version must look like 1.2.3")
    if os.path.exists(out):
        # only ever delete a folder this tool created
        if not os.path.exists(os.path.join(out, MARKER)):
            sys.exit("%s exists and is not a BuildKit release folder; refusing to overwrite" % out)
        shutil.rmtree(out)
    os.makedirs(out)
    open(os.path.join(out, MARKER), "w").close()

    shared = [(p, "/bs/" + p) for p in lua_files(root, "lib") + lua_files(root, "install")]
    shared.append(("roles/_common/startup.lua", "/startup.lua"))
    shared.append(("roles/_common/setup.lua", "/setup.lua"))
    # vendored libraries live at /bs/<name>/ so `require "ccryptolib.aead"` works in-game
    shared += [(p, "/bs/" + p[len("vendor/"):]) for p in lua_files(root, "vendor")]
    roles = sorted(d for d in os.listdir(os.path.join(root, "roles"))
                   if not d.startswith("_") and os.path.isdir(os.path.join(root, "roles", d)))

    manifest = {"version": version, "roles": {}}
    for role in roles:
        prefix = "roles/%s/" % role
        # main.lua and config.lua live at /bs/role/ (same place on every computer);
        # the role's other modules keep their repo path so require("roles.<role>.<name>") works in-game
        own = [(p, ("/bs/role/" if p[len(prefix):] in ("main.lua", "config.lua") else "/bs/" + prefix) + p[len(prefix):])
               for p in lua_files(root, "roles/" + role)]
        entries = []
        for path, dest in shared + own:
            data = open(os.path.join(root, path), "rb").read()
            target = os.path.join(out, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data)
            entries.append({"path": path, "dest": dest, "size": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()})
        manifest["roles"][role] = entries

    lines = ['return { version = "%s", roles = {' % version]
    for role in roles:
        lines.append('  ["%s"] = {' % role)
        for e in manifest["roles"][role]:
            lines.append('    { path = "%(path)s", dest = "%(dest)s", size = %(size)d, sha256 = "%(sha256)s" },' % e)
        lines.append("  },")
    lines.append("} }")
    with open(os.path.join(out, "manifest.lua"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    write_bundle(out)
    return manifest


def lua_long_string(text):
    """Lua long-bracket literal for text, picking a bracket level the text does not contain."""
    level = 1
    while "]" + "=" * level + "]" in text:
        level += 1
    eq = "=" * level
    # Lua drops a newline right after the opening bracket, so always add one
    return "[%s[\n%s]%s]" % (eq, text, eq)


def write_bundle(out):
    """One self-extracting file (buildkit.lua) holding the whole release.

    In-game: drag it onto a computer's screen, then run `buildkit <role>`.
    """
    files = []
    for folder, _dirs, names in os.walk(out):
        for name in sorted(names):
            if name.endswith(".lua") and name != "buildkit.lua":
                rel = os.path.relpath(os.path.join(folder, name), out).replace(os.sep, "/")
                files.append(rel)
    parts = [BUNDLE_HEAD]
    for rel in sorted(files):
        text = open(os.path.join(out, rel), encoding="latin-1", newline="").read()
        if "\r" in text:
            sys.exit("%s contains carriage returns; cannot bundle" % rel)
        parts.append('F["%s"] = %s\n' % (rel, lua_long_string(text)))
    parts.append(BUNDLE_TAIL)
    with open(os.path.join(out, "buildkit.lua"), "w", encoding="latin-1", newline="\n") as f:
        f.write("".join(parts))


BUNDLE_HEAD = """-- BuildKit release bundle. Drag this file onto a computer, then run:  buildkit
-- It unpacks itself and opens the setup screen (or: buildkit <role> to install without the screen).
local args = { ... }
local F = {}
"""

BUNDLE_TAIL = """
local DIR = "/bs-release"
if fs.exists(DIR) then fs.delete(DIR) end
-- This file is already loaded in memory, so delete it from the disk FIRST: the computer does not
-- have room for the bundle and its unpacked copy at the same time.
local me = shell.getRunningProgram()
if me and fs.exists(me) then fs.delete(me) end
for path, text in pairs(F) do
  local h = fs.open(DIR .. "/" .. path, "w")
  h.write(text)
  h.close()
end
F = nil
local ok
if args[1] == "unpack" then
  print("Unpacked to " .. DIR)
  return
elseif args[1] then
  ok = shell.run(DIR .. "/install/install.lua", args[1])
else
  -- no role given: open the click-to-install setup screen
  ok = shell.run(DIR .. "/install/setup.lua")
end
if ok and fs.exists("/bs/.version") and not fs.exists("/bs/.installing") then
  fs.delete(DIR)
  print("Release files cleaned up.")
else
  print("Nothing was installed. Release files are still in " .. DIR .. " (run " .. DIR .. "/install/setup).")
end
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", default="dist")
    args = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    manifest = build(root, args.out, args.version)
    total = sum(e["size"] for e in manifest["roles"]["compute"])
    print("Release %s written to %s (%d roles, about %d KB per computer)"
          % (args.version, args.out, len(manifest["roles"]), total // 1024))


if __name__ == "__main__":
    main()
