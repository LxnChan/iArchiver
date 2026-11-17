#!/usr/bin/env python3
"""Record local evidence without confusing it with Apple platform validation."""
import argparse
import datetime
import json
import pathlib
import platform
import re
import subprocess
import sys
from bootstrap import ROOT

parser = argparse.ArgumentParser()
parser.add_argument("--build", action="store_true", help="Build both native variants before testing")
args = parser.parse_args()
output = ROOT / "Build" / "validation"
output.mkdir(parents=True, exist_ok=True)
steps = []
commands = []
if args.build:
    commands.append(("native-build", ["Scripts/build_native.py"]))
commands += [("test-fixtures", ["Scripts/generate_test_fixtures.py"]),
             ("resources", ["Scripts/generate_resources.py"]),
             ("project", ["Scripts/generate_project.py"]),
             ("structure", ["Scripts/validate_repository.py"]),
             ("native-tests", ["Tests/native/test_archive_core.py"])]
for name, arguments in commands:
    print(f"Running {name}", flush=True)
    result = subprocess.run([sys.executable] + arguments, cwd=ROOT, capture_output=True)
    combined = result.stdout + result.stderr
    (output / (name + ".log")).write_bytes(combined)
    text = combined.decode("utf-8", "replace")
    steps.append({"name": name, "passed": result.returncode == 0})
    if name == "native-tests":
        match = re.search(r"Ran (\d+) tests", text)
        if match:
            steps[-1]["tests"] = int(match.group(1))
    if result.returncode:
        print(text)
        raise SystemExit(result.returncode)
report = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat(), "host": platform.platform(),
          "steps": steps, "appleBuildPerformed": False, "swiftXCTestPerformed": False,
          "warning": "Local syntax/host checks are not Apple SDK compilation or device verification."}
(output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("PASS: local checks. Evidence: Build/validation/report.json. Apple compilation and devices remain unverified.")
