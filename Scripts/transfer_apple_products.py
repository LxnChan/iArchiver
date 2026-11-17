#!/usr/bin/env python3
"""Transfer the exact unsigned Apple products between jobs in one Actions run."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import tarfile
from bootstrap import ROOT


def product_paths():
    yield "Build/Apple"
    for variant in ["AppStore", "Sideload"]:
        for platform, sdk in [("Simulator", "iphonesimulator"), ("Device", "iphoneos")]:
            yield f"Build/DerivedData-{variant}-{platform}/Build/Products/Release-{sdk}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["create", "restore"])
    options = parser.parse_args()
    transfer = ROOT / "Build" / "Transfer"
    archive = transfer / "apple-products.tar.gz"
    metadata = transfer / "apple-products.json"
    commit = os.environ["GITHUB_SHA"]
    if options.operation == "create":
        transfer.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "w:gz") as output:
            for path in product_paths():
                if not (ROOT / path).is_dir():
                    raise RuntimeError(f"Missing validated Apple product directory: {path}")
                output.add(ROOT / path, arcname=path)
        with archive.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        metadata.write_text(json.dumps({"schema": 1, "commit": commit, "sha256": digest}, indent=2) + "\n")
        print(f"Staged {archive.stat().st_size:,} bytes of unsigned Apple products for {commit}.")
    else:
        info = json.loads(metadata.read_text())
        if info.get("schema") != 1 or info.get("commit") != commit:
            raise RuntimeError("Apple products belong to a different schema or source commit")
        with archive.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != info["sha256"]:
                raise RuntimeError("Apple product transfer checksum mismatch")
        with tarfile.open(archive) as source:
            if any(not item.name.startswith("Build/") for item in source.getmembers()):
                raise RuntimeError("Apple transfer contains an unexpected root path")
            source.extractall(ROOT, filter="data")
        for path in product_paths():
            if not (ROOT / path).is_dir():
                raise RuntimeError(f"Restored Apple products are incomplete: {path}")
        print(f"Restored the validated unsigned Apple products for {commit}.")


if __name__ == "__main__":
    main()
