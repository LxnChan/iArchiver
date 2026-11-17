#!/usr/bin/env python3
"""Fetch only locked upstream sources; never execute downloaded scripts."""
from __future__ import annotations
import hashlib
import json
import pathlib
import shutil
import stat
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]


def bootstrap() -> dict[str, pathlib.Path]:
    lock = json.loads((ROOT / "Dependencies.lock.json").read_text(encoding="utf-8"))
    downloads = ROOT / ".deps" / "downloads"
    sources = ROOT / ".deps" / "src"
    downloads.mkdir(parents=True, exist_ok=True)
    sources.mkdir(parents=True, exist_ok=True)
    result = {}
    for item in lock["dependencies"]:
        archive = ROOT / item["vendor_archive"] if "vendor_archive" in item else downloads / f"{item['directory']}.tar.gz"
        if not archive.exists():
            temporary = archive.with_suffix(".part")
            print(f"Downloading {item['name']} {item['version']}", flush=True)
            request = urllib.request.Request(item["url"], headers={"User-Agent": "iArchiver-build/0.1"})
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            temporary.replace(archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            raise RuntimeError(f"Checksum mismatch: {archive.name}; refusing to build")
        destination = sources / item["directory"]
        stamp = destination / ".iarchiver-source-sha256"
        if not stamp.exists() or stamp.read_text() != digest:
            if destination.exists():
                for existing in destination.rglob("*"):
                    if existing.is_file() and not existing.is_symlink():
                        existing.chmod(existing.stat().st_mode | stat.S_IWUSR)
            # tarfile's data filter rejects links outside the extraction root.
            with tarfile.open(archive) as compressed:
                for member in compressed.getmembers():
                    parts = pathlib.PurePosixPath(member.name).parts
                    if not parts or parts[0] != item["directory"]:
                        raise RuntimeError(f"Unexpected source layout: {member.name}")
                compressed.extractall(sources, filter="data")
            stamp.write_text(digest)
        result[item["name"]] = destination
    return result


if __name__ == "__main__":
    for name, location in bootstrap().items():
        print(f"{name}: {location}")

