#!/usr/bin/env python3
"""Run Release XCUITest assertions on each required device family, both variants."""
from __future__ import annotations
import argparse
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import time
from bootstrap import ROOT
from picker_fixtures import FIXTURE_DIRECTORY, LARGE_ARCHIVE, LARGE_SIZE, write_archive


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?(?:$|[^0-9])", identifier)
    return tuple(int(part or 0) for part in match.groups()) if match else (0, 0, 0)


def logged(arguments, path, timeout=120, check=True, progress=False):
    print(f"Running {path.stem}", flush=True)
    started = time.monotonic()
    with path.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(arguments, cwd=ROOT, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            with path.open(encoding="utf-8", errors="replace") as reader:
                while True:
                    remaining = timeout - (time.monotonic() - started)
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(arguments, timeout)
                    try:
                        process.wait(timeout=min(30, remaining))
                    except subprocess.TimeoutExpired:
                        if progress:
                            lines = reader.read().splitlines()
                            for line in lines:
                                if line.startswith(("Test Case ", "Test Suite ")) or "error:" in line:
                                    print(line, flush=True)
                            print(f"{path.stem}: running ({time.monotonic() - started:.0f}s)", flush=True)
                        continue
                    if progress:
                        for line in reader.read().splitlines():
                            if line.startswith(("Test Case ", "Test Suite ")) or "error:" in line:
                                print(line, flush=True)
                    break
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
    print(f"Finished {path.stem} in {time.monotonic() - started:.1f}s (exit {process.returncode})", flush=True)


def prepare_picker_fixtures(device, variant, logs, name):
    product = "iArchiver" if variant == "AppStore" else "iArchiver Sideload"
    app = (ROOT / f"Build/DerivedData-UI-{variant}/Build/Products"
           / "Release-iphonesimulator" / (product + ".app"))
    with (app / "Info.plist").open("rb") as stream:
        bundle_id = plistlib.load(stream)["CFBundleIdentifier"]
    # Only install the ad hoc SIGNED build-for-testing product, never the
    # unsigned distribution app. A normal subsequent XCTest install keeps data.
    logged(["xcrun", "simctl", "install", device["udid"], str(app)],
           logs / (name + "-install.log"), timeout=120)
    container = pathlib.Path(subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", device["udid"], bundle_id, "data"],
        text=True, timeout=30).strip())
    documents = container / "Documents"
    fixtures = documents / FIXTURE_DIRECTORY
    fixtures.mkdir(parents=True, exist_ok=True)
    archive = fixtures / LARGE_ARCHIVE
    write_archive(archive)
    if archive.stat().st_size != LARGE_SIZE:
        raise RuntimeError("Large document-picker fixture has the wrong logical size")
    print(f"Prepared real picker source: {archive.name}, {archive.stat().st_size} bytes", flush=True)
    (logs / (name + "-picker-fixture.json")).write_text(json.dumps({
        "name": archive.name, "logicalBytes": archive.stat().st_size,
        "description": "Valid 7z with one empty file and a sparse gap before NextHeader; import copies all bytes.",
    }, indent=2) + "\n")
    return documents


def test_variant(device, variant, results, logs):
    name = f"ui-{variant}-{device['family']}"
    screenshots = ROOT / "Build" / "Screenshots" / name
    screenshots.mkdir(parents=True, exist_ok=True)
    # Xcode installs an ad hoc signed Release test build in its own directory.
    # The distribution products stay unsigned and are never modified here.
    arguments = ["-project", "iArchiver.xcodeproj",
        "-scheme", f"iArchiver-{variant}", "-configuration", "Release",
        "-destination", f"platform=iOS Simulator,id={device['udid']}",
        "-destination-timeout", "120", "-parallel-testing-enabled", "NO",
        "-maximum-concurrent-test-simulator-destinations", "1",
        "-derivedDataPath", f"Build/DerivedData-UI-{variant}",
        # Simulator-only ad hoc signing uses no Apple account or private key.
        "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM="]
    documents = None
    try:
        # Cold SDK/module compilation must not consume the UI execution budget.
        logged(["xcodebuild", "build-for-testing", *arguments],
            logs / (name + "-build.log"), timeout=900)
        documents = prepare_picker_fixtures(device, variant, logs, name)
        logged(["xcodebuild", "test-without-building", *arguments,
            "-resultBundlePath", str(results / (name + ".xcresult"))],
            # Duo's native menu can use XCTest's 60-second animation waits;
            # include the real 5 GiB picker/import regression and finalization.
            logs / (name + ".log"), timeout=900, progress=True)
        print(f"::notice title=Simulator test passed::{name}: {device['name']}", flush=True)
    finally:
        try:
            logged(["xcrun", "simctl", "spawn", device["udid"], "log", "show",
                    "--last", "20m", "--style", "compact", "--predicate",
                    'category == "DocumentPicker" OR category == "FileImport"'],
                   logs / (name + "-picker.log"), timeout=45, check=False)
        except Exception as error:
            print(f"Picker diagnostics unavailable: {error}", flush=True)
        if documents is not None:
            shutil.rmtree(documents / FIXTURE_DIRECTORY, ignore_errors=True)
            (documents / LARGE_ARCHIVE).unlink(missing_ok=True)
        bundle = results / (name + ".xcresult")
        if bundle.exists():
            try:
                logged(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                    "--output-path", str(screenshots / "Attachments")], logs / (name + "-attachments.log"), timeout=45, check=False)
            except subprocess.TimeoutExpired:
                print(f"Screenshot export timed out; retaining {bundle}.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=["iPhone", "iPad", "Duo"],
        help="CI runs each family on a separate Apple host")
    options = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))["devices"]
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True))["runtimes"]
    versions = {runtime["identifier"]: tuple(int(part) for part in (runtime["version"].split(".") + ["0", "0"])[:3]) for runtime in runtimes}
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
    sdk_version = tuple(int(part) for part in (sdk.split(".") + ["0", "0"])[:3])
    selected = []
    for family in ([options.family] if options.family else ["iPhone", "iPad", "Duo"]):
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
    print("PASS: both Release variants passed XCUITest on " + ", ".join(device["family"] for device in selected), flush=True)


if __name__ == "__main__":
    main()
