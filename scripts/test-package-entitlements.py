#!/usr/bin/env python3
"""Isolated policy fixtures; no app launches, signing, or user data access."""
import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SCRIPT = Path(__file__).with_name("verify-package-entitlements.py")
spec = importlib.util.spec_from_file_location("package_entitlements", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
READ = policy.READ_ONLY_EXCEPTION
WRITE = policy.EXCEPTION_PREFIX + "files.absolute-path.read-write"


class PackageEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="filicon-entitlements-")
        self.addCleanup(self.fixture.cleanup)  # Only this owned fixture.
        self.root = Path(self.fixture.name).resolve()
        self.bundle = self.root / "空白 project" / "Filicon.app"
        self.bundle.mkdir(parents=True)
        self.exact = str(self.bundle) + "/"

    def check(self, app=None, xpc=None, development=True):
        policy.verify_policy({} if app is None else app,
                             {READ: [self.exact]} if xpc is None else xpc,
                             str(self.bundle), development)

    def test_exact_debug_path_and_shipping_without_exceptions(self):
        self.check()
        self.check(xpc={}, development=False)
        self.check(app={policy.DEBUGGER: True},
                   xpc={READ: [self.exact], policy.DEBUGGER: True})

    def test_real_macos_system_aliases_and_canonical_spelling(self):
        # Use both actual system aliases. Never create/modify system symlinks.
        for alias, canonical in (("/var", "/private/var"), ("/tmp", "/private/tmp")):
            with self.subTest(alias=alias):
                self.assertTrue(os.path.islink(alias), "This is a macOS regression suite")
                self.assertEqual(os.path.realpath(alias), canonical)
                parent = "/var/tmp" if alias == "/var" else alias
                with tempfile.TemporaryDirectory(prefix="filicon-alias-", dir=parent) as directory:
                    bundle = Path(directory) / "空白 Filicon.app"
                    bundle.mkdir()
                    expected = os.path.realpath(bundle)
                    alternate = alias + expected[len(canonical):] + "/"
                    policy.verify_policy({}, {READ: [expected + "/"]}, expected, True)
                    policy.verify_policy({}, {READ: [alternate]}, expected, True)

    def test_system_alias_must_be_root_owned_and_point_to_expected_target(self):
        with tempfile.TemporaryDirectory(prefix="filicon-alias-", dir="/var/tmp") as directory:
            bundle = Path(directory) / "Filicon.app"
            bundle.mkdir()
            expected = os.path.realpath(bundle)
            alternate = "/var" + expected[len("/private/var"):] + "/"
            for target in ("private/elsewhere", "/private/tmp"):
                with self.subTest(target=target), patch.object(policy.os, "readlink", return_value=target):
                    with self.assertRaises(ValueError):
                        policy.verify_policy({}, {READ: [alternate]}, expected, True)
            with patch.object(policy.os, "lstat", side_effect=OSError("unavailable")):
                with self.assertRaises(ValueError):
                    policy.verify_policy({}, {READ: [alternate]}, expected, True)
            for metadata in (SimpleNamespace(st_uid=501, st_mode=stat.S_IFLNK),
                             SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR)):
                with self.subTest(metadata=metadata), patch.object(policy.os, "lstat", return_value=metadata):
                    with self.assertRaises(ValueError):
                        policy.verify_policy({}, {READ: [alternate]}, expected, True)

    def test_arbitrary_symlink_to_same_bundle_is_not_accepted(self):
        link = self.root / "alias.app"
        link.symlink_to(self.bundle, target_is_directory=True)
        self.assertEqual(link.resolve(), self.bundle)
        with self.assertRaises(ValueError):
            self.check(xpc={READ: [str(link) + "/"]})
        parent_link = self.root / "parent-alias"
        parent_link.symlink_to(self.bundle.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.check(xpc={READ: [str(parent_link / "Filicon.app") + "/"]})

    def test_alias_matching_uses_a_whole_prefix_and_accepts_absolute_system_target(self):
        for path in ("/private/variable/Filicon.app", "/private/tmp-other/Filicon.app",
                     "/Users/fixture/Filicon.app"):
            with self.subTest(path=path):
                self.assertEqual(policy.debug_bundle_paths(path), {path + "/"})
        metadata = SimpleNamespace(st_uid=0, st_mode=stat.S_IFLNK)
        with patch.object(policy.os, "lstat", return_value=metadata), \
                patch.object(policy.os, "readlink", return_value="/private/var"):
            self.assertEqual(policy.debug_bundle_paths("/private/var/fixture/Filicon.app"),
                             {"/private/var/fixture/Filicon.app/", "/var/fixture/Filicon.app/"})

    def test_parent_child_sibling_traversal_wildcard_and_malformed_paths_fail(self):
        for path in ("/", str(self.bundle.parent) + "/", self.exact + "Contents/",
                     self.exact + "../", self.exact + "../Filicon.app/",
                     self.exact.replace("Filicon.app", "Filicon.app-other"),
                     self.exact[:-1], self.exact + "/", self.exact + "\0",
                     self.exact + "*", self.exact + "\n", "~/Filicon.app/",
                     "file://" + self.exact, "Filicon.app/", "", "/various/Filicon.app/"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check(xpc={READ: [path]})

    def test_exception_shape_and_extra_permissions_fail(self):
        for value in ([], [self.exact, self.exact], [self.exact, "/"],
                      self.exact, True, 1, None, [{}], [False]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(xpc={READ: value})
        for value in ({}, {WRITE: [self.exact]}, {READ: [self.exact], WRITE: []},
                      {READ: [self.exact], policy.EXCEPTION_PREFIX + "mach-lookup.global-name": []}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(xpc=value)

    def test_app_cannot_gain_exception_in_either_mode(self):
        for development in (True, False):
            for value in ({READ: [self.exact]}, {WRITE: []}):
                with self.subTest(development=development, value=value), self.assertRaises(ValueError):
                    self.check(app=value, xpc=None if development else {}, development=development)

    def test_release_rejects_debug_exception_and_debugger_on_either_product(self):
        for app, xpc in (({}, {READ: [self.exact]}), ({}, {WRITE: []}),
                         ({policy.DEBUGGER: True}, {}), ({}, {policy.DEBUGGER: True})):
            with self.subTest(app=app, xpc=xpc), self.assertRaises(ValueError):
                self.check(app=app, xpc=xpc, development=False)

    def test_invalid_root_shapes_and_build_modes_fail(self):
        for app, xpc, mode in (([], {}, True), ({}, [], True), ({}, {}, "false"), ({1: True}, {}, True)):
            with self.subTest(app=app, xpc=xpc, mode=mode), self.assertRaises(ValueError):
                policy.verify_policy(app, xpc, str(self.bundle), mode)

    def test_cli_accepts_both_plist_encodings_and_rejects_bad_inputs(self):
        app_file, xpc_file = self.root / "app.plist", self.root / "xpc.plist"
        command = [sys.executable, "-B", str(SCRIPT), str(app_file), str(xpc_file), str(self.bundle), "true"]
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                app_file.write_bytes(plistlib.dumps({}, fmt=fmt))
                xpc_file.write_bytes(plistlib.dumps({READ: [self.exact]}, fmt=fmt))
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        xpc_file.write_bytes(plistlib.dumps({READ: ["/"]}))
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sandbox exceptions", result.stderr)
        xpc_file.write_bytes(b"not a plist")
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(command[:-1] + ["unexpected"], capture_output=True).returncode, 2)
        self.assertEqual(subprocess.run(command[:-1], capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
