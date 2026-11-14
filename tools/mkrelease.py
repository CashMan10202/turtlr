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
    roles = sorted(d for d in os.listdir(os.path.join(root, "roles"))
                   if not d.startswith("_") and os.path.isdir(os.path.join(root, "roles", d)))

    manifest = {"version": version, "roles": {}}
    for role in roles:
        prefix = "roles/%s/" % role
        own = [(p, "/bs/role/" + p[len(prefix):]) for p in lua_files(root, "roles/" + role)]
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
    return manifest


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
