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
    explicit = bool(os.environ.get("DEVELOPER_DIR"))
    if os.environ.get("DEVELOPER_DIR"):
        candidates = [pathlib.Path(os.environ["DEVELOPER_DIR"])]
    else:
        candidates = [path / "Contents" / "Developer" for path in pathlib.Path("/Applications").glob("Xcode*.app")]
    available = []
    for path in candidates:
        if not explicit and "beta" in str(path).lower():
            continue
        env = dict(os.environ, DEVELOPER_DIR=str(path))
        release = subprocess.run(["xcodebuild", "-version"], env=env, capture_output=True, text=True)
        if not explicit and "beta" in release.stdout.lower():
            continue
        result = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env=env, capture_output=True, text=True)
        try:
            version = tuple(int(part) for part in result.stdout.strip().split("."))
        except ValueError:
            continue
        if result.returncode == 0 and version >= (27, 1):
            available.append((version, str(path)))
    if not available:
        raise SystemExit("No stable iOS 27.1+ SDK found. Install Xcode with that SDK; Duo reservedRegions needs 27.1. Deployment remains iOS 18. Set DEVELOPER_DIR explicitly for intentional beta testing.")
    print(sorted(available)[-1][1])


if __name__ == "__main__":
    main()
