#!/usr/bin/env python3
"""Find a public iOS 27.1+ SDK. Prints only DEVELOPER_DIR for safe shell use."""
import os
import pathlib
import platform
import subprocess
import sys


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Apple builds require a Mac with Xcode 27.1 or newer.")
    candidates = []
    # Actions can prepopulate DEVELOPER_DIR with an older default Xcode.
    # An intentional override uses a project-specific variable instead.
    explicit = bool(os.environ.get("IARCHIVER_XCODE_PATH"))
    if explicit:
        candidates = [pathlib.Path(os.environ["IARCHIVER_XCODE_PATH"])]
    else:
        candidates = [path / "Contents" / "Developer" for path in pathlib.Path("/Applications").glob("Xcode*.app")]
    available = []
    inventory = []
    for path in candidates:
        if not explicit and "beta" in str(path).lower():
            continue
        env = dict(os.environ, DEVELOPER_DIR=str(path))
        release = subprocess.run(["xcodebuild", "-version"], env=env, capture_output=True, text=True)
        if not explicit and "beta" in release.stdout.lower():
            continue
        result = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env=env, capture_output=True, text=True)
        inventory.append(f"{path}: {release.stdout.strip()}, iOS SDK {result.stdout.strip()}")
        try:
            version = tuple(int(part) for part in result.stdout.strip().split("."))
        except ValueError:
            continue
        if result.returncode == 0 and version >= (27, 1):
            available.append((version, str(path)))
    if not available:
        print("\n".join(inventory), file=sys.stderr)
        raise SystemExit("No stable iOS 27.1+ SDK found. Use the GitHub xcode-27 runner. Duo reservedRegions needs 27.1; deployment remains iOS 18. IARCHIVER_XCODE_PATH explicitly selects a toolchain for intentional beta testing.")
    print(sorted(available)[-1][1])


if __name__ == "__main__":
    main()
