#!/usr/bin/env python3
"""Additional signed-entitlement policy; verify-package.sh still verifies seals."""
import os
import plistlib
import stat
import sys

EXCEPTION_PREFIX = "com.apple.security.temporary-exception."
READ_ONLY_EXCEPTION = EXCEPTION_PREFIX + "files.absolute-path.read-only"
DEBUGGER = "com.apple.security.get-task-allow"


def debug_bundle_paths(app_path):
    # The caller supplies the validated, canonical app path. Do NOT realpath
    # a signed exception: that could accept a user-controlled symlink which
    # could later be retargeted. Only these root-owned macOS aliases qualify.
    paths = {app_path + "/"}
    for alias, target in (("/var", "/private/var"), ("/tmp", "/private/tmp")):
        if not app_path.startswith(target + "/"):
            continue
        try:
            metadata = os.lstat(alias)
            link = os.readlink(alias)
        except OSError:
            continue
        if (metadata.st_uid == 0 and stat.S_ISLNK(metadata.st_mode)
                and link in (target, target.lstrip("/"))):
            paths.add(alias + app_path[len(target):] + "/")
    return paths


def verify_policy(app, xpc, app_path, development):
    if not isinstance(app, dict) or not isinstance(xpc, dict):
        raise ValueError("Signed entitlements must be dictionaries")
    if any(not isinstance(key, str) for values in (app, xpc) for key in values):
        raise ValueError("Signed entitlement keys must be strings")
    if not isinstance(development, bool):
        raise ValueError("Build mode must be explicit")
    exceptions = {key: value for key, value in xpc.items()
                  if key.startswith(EXCEPTION_PREFIX)}
    if development:
        paths = exceptions.get(READ_ONLY_EXCEPTION)
        valid = (set(exceptions) == {READ_ONLY_EXCEPTION}
                 and isinstance(paths, list) and len(paths) == 1
                 and isinstance(paths[0], str)
                 and paths[0] in debug_bundle_paths(app_path))
    else:
        valid = not exceptions
    if not valid:
        raise ValueError("XPC sandbox exceptions do not match the requested build mode")
    if any(key.startswith(EXCEPTION_PREFIX) for key in app):
        raise ValueError("Unexpected app sandbox exception")
    if not development and any(values.get(DEBUGGER, False) for values in (app, xpc)):
        raise ValueError("Shipping bundle must not allow debugger attachment")


def main(argv):
    if len(argv) != 4 or argv[3] not in ("true", "false"):
        print("usage: verify-package-entitlements.py APP_PLIST XPC_PLIST APP_PATH true|false",
              file=sys.stderr)
        return 2
    try:
        with open(argv[0], "rb") as stream:
            app = plistlib.load(stream)
        with open(argv[1], "rb") as stream:
            xpc = plistlib.load(stream)
        verify_policy(app, xpc, os.path.realpath(argv[2]), argv[3] == "true")
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
