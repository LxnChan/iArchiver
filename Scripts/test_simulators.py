#!/usr/bin/env python3
"""Run actual XCUITest assertions on each required device family, both variants."""
from __future__ import annotations
import json
import pathlib
import re
import subprocess
from bootstrap import ROOT


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?(?:$|[^0-9])", identifier)
    return tuple(int(part or 0) for part in match.groups()) if match else (0, 0, 0)


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
                    choices.append((version, name, device["udid"]))
        if not choices:
            raise RuntimeError(f"No iOS 27 simulator for {family}; required coverage cannot be skipped")
        version, name, udid = sorted(choices)[-1]
        selected.append({"family": family, "name": name, "runtime": version, "udid": udid})

    results = ROOT / "Build" / "TestResults"
    logs = ROOT / "Build" / "logs"
    results.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    (results / "simulator-matrix.json").write_text(json.dumps(selected, indent=2) + "\n")
    failures = []
    for device in selected:
        for variant in ["AppStore", "Sideload"]:
            name = f"ui-{variant}-{device['family']}"
            print(f"Running {name} on {device['name']} ({device['runtime']})", flush=True)
            arguments = ["xcodebuild", "test", "-project", "iArchiver.xcodeproj",
                "-scheme", f"iArchiver-{variant}", "-configuration", "Debug",
                "-destination", f"platform=iOS Simulator,id={device['udid']}",
                "-destination-timeout", "120", "-parallel-testing-enabled", "NO",
                "-maximum-concurrent-test-simulator-destinations", "1",
                "-derivedDataPath", f"Build/DerivedData-UI-{variant}",
                "-resultBundlePath", str(results / (name + ".xcresult")), "CODE_SIGNING_ALLOWED=NO"]
            try:
                with (logs / (name + ".log")).open("w", encoding="utf-8") as output:
                    result = subprocess.run(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=600)
                if result.returncode:
                    failures.append(name)
                    print((logs / (name + ".log")).read_text(errors="replace")[-18000:], flush=True)
            except subprocess.TimeoutExpired:
                failures.append(name + " (10 minute timeout)")
            finally:
                subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]], capture_output=True)
                bundle = results / (name + ".xcresult")
                if bundle.exists():
                    screenshots = ROOT / "Build" / "Screenshots" / name
                    screenshots.mkdir(parents=True, exist_ok=True)
                    exported = subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                        "--path", str(bundle), "--output-path", str(screenshots)], capture_output=True, text=True)
                    if exported.returncode:
                        print(f"Screenshot export unavailable; attachments remain in {bundle}: {exported.stderr[-1000:]}", flush=True)
    if failures:
        raise RuntimeError("Simulator UI checks failed: " + ", ".join(failures))
    print("PASS: both variants passed XCUITest on iPhone, iPad and iPhone Duo.", flush=True)


if __name__ == "__main__":
    main()
