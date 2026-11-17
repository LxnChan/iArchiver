#!/usr/bin/env python3
"""Package validated, unsigned products. No certificates or signing secrets."""
from __future__ import annotations
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from bootstrap import ROOT


def zipped(source: pathlib.Path, destination: pathlib.Path):
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(destination)], check=True)


def main():
    output = ROOT / "Build" / "Artifacts"
    output.mkdir(parents=True, exist_ok=True)
    products = []
    for variant, product in [("AppStore", "iArchiver"), ("Sideload", "iArchiver Sideload")]:
        for platform, sdk in [("Device", "iphoneos"), ("Simulator", "iphonesimulator")]:
            folder = ROOT / "Build" / f"DerivedData-{variant}-{platform}" / "Build" / "Products" / ("Release-" + sdk)
            app = folder / (product + ".app")
            info = plistlib.loads((app / "Info.plist").read_bytes())
            if (app / "embedded.mobileprovision").exists() or (app / "_CodeSignature").exists():
                raise RuntimeError(f"Expected unsigned product: {app}")
            name = f"iArchiver-{variant}-{platform}-unsigned"
            if platform == "Device":
                destination = output / (name + ".ipa")
                with tempfile.TemporaryDirectory(prefix="iarchiver-package-") as stage:
                    payload = pathlib.Path(stage) / "Payload"
                    shutil.copytree(app, payload / app.name)
                    zipped(payload, destination)
            else:
                destination = output / (name + ".zip")
                zipped(app, destination)
            symbols = folder / (product + ".app.dSYM")
            if symbols.exists():
                zipped(symbols, output / (name + "-dSYM.zip"))
            products.append({"file": destination.name, "bundleIdentifier": info["CFBundleIdentifier"],
                             "minimumOSVersion": info["MinimumOSVersion"], "signed": False})
        framework = ROOT / "Build" / "Apple" / f"ArchiveCore-{variant.lower()}.xcframework"
        zipped(framework, output / (framework.name + ".zip"))
    manifest = {"commit": os.environ.get("GITHUB_SHA", "local"), "runID": os.environ.get("GITHUB_RUN_ID"),
                "products": products,
                "sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.iterdir()) if path.suffix in {".zip", ".ipa"}}}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "READ-ME.txt").write_text(
        "UNSIGNED VALIDATION PRODUCTS\n\n"
        "Device IPA files require your own Apple certificate, bundle IDs, entitlements and provisioning before installation.\n"
        "They cannot be installed directly or submitted to App Store Connect in this form.\n"
        "Simulator ZIP files contain arm64 .app bundles. Unzip on an Apple silicon Mac and install with simctl.\n"
        "AppStore excludes UnRAR; Sideload includes it. Neither variant creates RAR.\n"
        "See apple-build-diagnostics for core results and apple-ui-diagnostics per device family for Release UI results and screenshots.\n",
        encoding="utf-8")
    print(f"Packaged {len(products)} unsigned app products in {output}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write("\n### Validation artifacts\n\nBoth variants: unsigned device IPA, arm64 simulator app, dSYM, native XCFramework, SHA-256 manifest.\n\n"
                          "Native integration tests, Swift core XCTest and six simulator UI runs completed before packaging.\n")


if __name__ == "__main__":
    main()
