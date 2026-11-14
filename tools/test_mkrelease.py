import hashlib, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import mkrelease


class MkReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = os.path.join(cls.tmp.name, "dist")
        cls.manifest = mkrelease.build(ROOT, cls.out, "1.2.3")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_roles_listed(self):
        for role in ["storage", "compute", "incoming", "outgoing", "register", "ingest", "monitor",
                     "worker", "pocket", "gps"]:
            self.assertIn(role, self.manifest["roles"])
        self.assertNotIn("_common", self.manifest["roles"])

    def test_hashes_and_sizes_match_files(self):
        for role, entries in self.manifest["roles"].items():
            for e in entries:
                data = open(os.path.join(self.out, e["path"]), "rb").read()
                self.assertEqual(len(data), e["size"], e["path"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), e["sha256"], e["path"])

    def test_every_role_gets_lib_startup_and_own_config(self):
        for role, entries in self.manifest["roles"].items():
            dests = {e["dest"]: e["path"] for e in entries}
            self.assertEqual(len(dests), len(entries), "duplicate destination in " + role)
            self.assertEqual(dests.get("/bs/lib/codec.lua"), "lib/codec.lua")
            self.assertEqual(dests.get("/startup.lua"), "roles/_common/startup.lua")
            self.assertEqual(dests.get("/bs/role/config.lua"), "roles/%s/config.lua" % role)
            self.assertIn("/bs/install/installer_core.lua", dests)
            self.assertEqual(dests.get("/setup.lua"), "roles/_common/setup.lua")
            self.assertIn("/bs/install/setup.lua", dests)
            self.assertEqual(dests.get("/bs/ccryptolib/aead.lua"), "vendor/ccryptolib/aead.lua")
            self.assertIn("/bs/ccryptolib/internal/util.lua", dests)
            for dest in dests:
                self.assertTrue(dest.endswith(".lua"), dest)
                self.assertFalse(dest.startswith("/bs/test/"), dest)

    def test_every_require_resolves_on_the_installed_computer(self):
        """In-game, require("a.b") loads /bs/a/b.lua. Every module a role's files ask for must be installed."""
        import re
        builtin = ("cc.",)
        for role, entries in self.manifest["roles"].items():
            dests = {e["dest"] for e in entries}
            for e in entries:
                src = open(os.path.join(self.out, e["path"]), encoding="latin-1").read()
                for mod in re.findall(r'require\s*\(?\s*"([^"]+)"', src):
                    if mod.startswith(builtin):
                        continue
                    want = "/bs/" + mod.replace(".", "/") + ".lua"
                    self.assertIn(want, dests, "%s (role %s) requires %s" % (e["path"], role, mod))

    def test_no_other_roles_files_leak(self):
        for e in self.manifest["roles"]["pocket"]:
            self.assertFalse(e["path"].startswith("roles/compute/"), e["path"])

    def test_manifest_loads_in_lua_and_matches(self):
        script = ('local m = dofile(os.getenv("MANIFEST")); local n = 0; '
                  'for _ in pairs(m.roles) do n = n + 1 end; '
                  'io.write(m.version, " ", n, " ", m.roles.gps[1].sha256)')
        out = subprocess.check_output(
            ["lua5.2", "-e", script], env=dict(os.environ, MANIFEST=os.path.join(self.out, "manifest.lua"))).decode()
        version, n, sha = out.split()
        self.assertEqual(version, "1.2.3")
        self.assertEqual(int(n), len(self.manifest["roles"]))
        self.assertEqual(sha, self.manifest["roles"]["gps"][0]["sha256"])

    def test_bundle_unpacks_to_identical_files(self):
        harness = """
package.path = "./?.lua;" .. package.path
local shim = require("test.cc_shim")
local e = shim.new()
local f = assert(io.open(os.getenv("BUNDLE"))); local src = f:read("*a"); f:close()
local ran
local env = setmetatable({ fs = e.fs, print = function() end,
  shell = { getRunningProgram = function() return "buildkit.lua" end,
            run = function(...) ran = table.concat({ ... }, " "); return true end } }, { __index = _G })
e.write("/buildkit.lua", src)
assert(load(src, "=bundle", "t", env))("gps")
assert(ran == "/bs-release/install/install.lua gps", ran)
-- with no role it opens the setup screen instead
e.write("/buildkit.lua", src)
assert(load(src, "=bundle", "t", env))()
assert(ran == "/bs-release/install/setup.lua", ran)
local function walk(dir)
  for _, name in ipairs(e.fs.list(dir)) do
    local p = dir .. "/" .. name
    if e.fs.isDir(p) then walk(p) else
      local out = assert(io.open(os.getenv("OUT") .. p:sub(#"/bs-release" + 1), "rb"))
      assert(out:read("*a") == e.read(p), "differs: " .. p); out:close()
      io.write(p:sub(#"/bs-release/" + 1), "\\n")
    end
  end
end
walk("/bs-release")
"""
        out = subprocess.check_output(["lua5.2", "-e", harness], cwd=ROOT,
                                      env=dict(os.environ, BUNDLE=os.path.join(self.out, "buildkit.lua"),
                                               OUT=self.out)).decode().split()
        expected = {e["path"] for entries in self.manifest["roles"].values() for e in entries} | {"manifest.lua"}
        self.assertEqual(set(out), expected)
        self.assertLess(os.path.getsize(os.path.join(self.out, "buildkit.lua")), 500000)  # CC upload limit 512 KB

    def test_installer_itself_is_in_the_release(self):
        self.assertTrue(os.path.exists(os.path.join(self.out, "install", "install.lua")))

    def test_rebuild_removes_stale_files(self):
        out = os.path.join(self.tmp.name, "dist2")
        mkrelease.build(ROOT, out, "1.0.0")
        stale = os.path.join(out, "lib", "stale.lua")
        open(stale, "w").write("x")
        mkrelease.build(ROOT, out, "1.0.1")
        self.assertFalse(os.path.exists(stale))

    def test_bad_version_rejected(self):
        with self.assertRaises(SystemExit):
            mkrelease.build(ROOT, self.out + "3", '1.0"; os.exit() --')


if __name__ == "__main__":
    unittest.main()
