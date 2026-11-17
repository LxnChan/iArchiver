#!/usr/bin/env python3
"""Run Release XCUITest assertions on each required device family, both variants."""
from __future__ import annotations
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import time
from bootstrap import ROOT


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?(?:$|[^0-9])", identifier)
    return tuple(int(part or 0) for part in match.groups()) if match else (0, 0, 0)


def logged(arguments, path, timeout=120, check=True):
    print(f"Running {path.stem}", flush=True)
    with path.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(arguments, cwd=ROOT, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
            print(path.read_text(errors="replace")[-18000:], flush=True)
            raise
    if check and process.returncode:
        print(path.read_text(errors="replace")[-18000:], flush=True)
        raise RuntimeError(f"{path.stem} failed with exit {process.returncode}")


def test_variant(device, variant, results, logs):
    name = f"ui-{variant}-{device['family']}"
    screenshots = ROOT / "Build" / "Screenshots" / name
    screenshots.mkdir(parents=True, exist_ok=True)
    product = "iArchiver" if variant == "AppStore" else "iArchiver Sideload"
    app = ROOT / "Build" / f"DerivedData-{variant}-Simulator" / "Build" / "Products" / "Release-iphonesimulator" / (product + ".app")
    bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    # First prove the release app starts without Xcode's debugger/test harness.
    # The runner's first install also initializes mobile installation services;
    # observed cold installs take about two minutes even after bootstatus.
    logged(["xcrun", "simctl", "install", device["udid"], str(app)], logs / (name + "-install.log"), timeout=240)
    logged(["xcrun", "simctl", "launch", device["udid"], bundle_id], logs / (name + "-launch.log"))
    time.sleep(3)
    logged(["xcrun", "simctl", "io", device["udid"], "screenshot", str(screenshots / "Release-initial-frame.png")], logs / (name + "-screenshot.log"))
    logged(["xcrun", "simctl", "terminate", device["udid"], bundle_id], logs / (name + "-terminate.log"))

    arguments = ["xcodebuild", "test", "-project", "iArchiver.xcodeproj",
        "-scheme", f"iArchiver-{variant}", "-configuration", "Release",
        "-destination", f"platform=iOS Simulator,id={device['udid']}",
        "-destination-timeout", "120", "-parallel-testing-enabled", "NO",
        "-maximum-concurrent-test-simulator-destinations", "1",
        "-derivedDataPath", f"Build/DerivedData-UI-{variant}",
        "-resultBundlePath", str(results / (name + ".xcresult")),
        # Simulator-only ad hoc signing uses no Apple account or private key.
        "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM="]
    try:
        logged(arguments, logs / (name + ".log"), timeout=300)
        print(f"::notice title=Simulator test passed::{name}: {device['name']}", flush=True)
    finally:
        bundle = results / (name + ".xcresult")
        if bundle.exists():
            try:
                logged(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                    "--output-path", str(screenshots / "Attachments")], logs / (name + "-attachments.log"), timeout=45, check=False)
            except subprocess.TimeoutExpired:
                print(f"Screenshot export timed out; retaining {bundle}.", flush=True)


def main():
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))["devices"]
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True))["runtimes"]
    versions = {runtime["identifier"]: tuple(int(part) for part in (runtime["version"].split(".") + ["0", "0"])[:3]) for runtime in runtimes}
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
    sdk_version = tuple(int(part) for part in (sdk.split(".") + ["0", "0"])[:3])
    selected = []
    for family in ["iPhone", "iPad", "Duo"]:
        choices = []
        for runtime, members in devices.items():
            version = versions.get(runtime, runtime_version(runtime))
            if not (27, 0, 0) <= version <= sdk_version:
                continue
            for device in members:
                name = device["name"]
                matches = (family == "Duo" and "Duo" in name or
                           family == "iPhone" and name.startswith("iPhone") and "Duo" not in name or
                           family == "iPad" and name.startswith("iPad"))
                if matches and device.get("isAvailable", False):
                    preferred = int(family == "iPad" and "Pro 13-inch" in name)
                    choices.append((version, preferred, name, device["udid"]))
        if not choices:
            raise RuntimeError(f"No iOS 27 simulator for {family}; required coverage cannot be skipped")
        version, _, name, udid = sorted(choices)[-1]
        selected.append({"family": family, "name": name, "runtime": version, "udid": udid})

    results = ROOT / "Build" / "TestResults"
    logs = ROOT / "Build" / "logs"
    results.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    (results / "simulator-matrix.json").write_text(json.dumps(selected, indent=2) + "\n")
    for device in selected:
        print(f"Preparing {device['family']}: {device['name']} ({device['runtime']})", flush=True)
        try:
            logged(["xcrun", "simctl", "boot", device["udid"]], logs / ("boot-" + device["family"] + ".log"), check=False)
            logged(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], logs / ("bootstatus-" + device["family"] + ".log"), timeout=240)
            # Keep one simulator warm for both variants; shut down before the
            # next family. First failure stops the suite and uploads evidence.
            for variant in ["AppStore", "Sideload"]:
                test_variant(device, variant, results, logs)
        except Exception:
            # Installation can hang before XCTest creates a result bundle.
            # Retain simulator service evidence even for those early failures.
            diagnostics = [
                (["xcrun", "simctl", "list", "-j"], "inventory"),
                (["/usr/bin/log", "show", "--last", "5m", "--style", "compact",
                  "--predicate", 'process == "simdiskimaged" OR process == "CoreSimulatorService"'], "services"),
                (["/usr/bin/vm_stat"], "memory"),
                (["/bin/df", "-h"], "disk"),
            ]
            for arguments, suffix in diagnostics:
                try:
                    logged(arguments, logs / f"simulator-{device['family']}-{suffix}.log", timeout=30, check=False)
                except Exception as error:
                    print(f"Diagnostic {suffix} unavailable: {error}", flush=True)
            raise
        finally:
            try:
                logged(["xcrun", "simctl", "shutdown", device["udid"]], logs / ("shutdown-" + device["family"] + ".log"), timeout=45, check=False)
            except subprocess.TimeoutExpired:
                print("Simulator shutdown timed out; retaining diagnostics.", flush=True)
    print("PASS: both variants passed XCUITest on iPhone, iPad and iPhone Duo.", flush=True)


if __name__ == "__main__":
    main()
