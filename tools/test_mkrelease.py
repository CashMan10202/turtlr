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
            self.assertEqual(dests.get("/bs/ccryptolib/aead.lua"), "vendor/ccryptolib/aead.lua")
            self.assertIn("/bs/ccryptolib/internal/util.lua", dests)
            for dest in dests:
                self.assertTrue(dest.endswith(".lua"), dest)
                self.assertFalse(dest.startswith("/bs/test/"), dest)

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
