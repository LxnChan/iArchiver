#!/usr/bin/env python3
"""Build native dependencies on the host, or reproducible iOS XCFrameworks."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
from bootstrap import ROOT, bootstrap
from patch_dependencies import apply_limits

JOBS = str(min(8, os.cpu_count() or 2))
LOGS = ROOT / "Build" / "logs"


def run(arguments: list[str], name: str) -> None:
    LOGS.mkdir(parents=True, exist_ok=True)
    log = LOGS / f"{name}.log"
    print(f"{name} …", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run([str(a) for a in arguments], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text(encoding="utf-8", errors="replace")[-14000:])
        raise RuntimeError(f"{name} failed; see {log}")


def configure_build(source: pathlib.Path, build: pathlib.Path, prefix: pathlib.Path,
                    options: list[str], apple: tuple[str, str] | None = None) -> None:
    args = ["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_PREFIX_PATH={prefix}",
            "-DCMAKE_INSTALL_LIBDIR=lib", "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"]
    if apple:
        sdk, arch = apple
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        args += ["-G", "Unix Makefiles", "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk_path}",
                 f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0",
                 "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO"]
    elif platform.system() == "Windows":
        args += ["-G", "Visual Studio 17 2022", "-A", "x64"]
    args += options
    configure_hash = hashlib.sha256(json.dumps(args).encode()).hexdigest()
    stamp = build / ".iarchiver-built"
    if stamp.exists() and stamp.read_text() == configure_hash:
        print(f"{build.name}: cached", flush=True)
        return
    run(args, f"{build.parent.name}-{build.name}-configure")
    run(["cmake", "--build", str(build), "--config", "Release", "--parallel", JOBS], f"{build.parent.name}-{build.name}-build")
    run(["cmake", "--install", str(build), "--config", "Release"], f"{build.parent.name}-{build.name}-install")
    stamp.write_text(configure_hash)


def build_dependencies(sources: dict, label: str, apple=None) -> pathlib.Path:
    patch_digest = apply_limits(sources["libarchive"])
    prefix = ROOT / ".deps" / "prefix" / label
    build = ROOT / "Build" / "native" / label
    configure_build(sources["zlib"], build / "zlib", prefix, [
        "-DZLIB_BUILD_SHARED=OFF", "-DZLIB_BUILD_STATIC=ON", "-DZLIB_BUILD_TESTING=OFF"], apple)
    configure_build(sources["xz"], build / "xz", prefix, [
        "-DBUILD_TESTING=OFF", "-DXZ_TOOL_XZ=OFF", "-DXZ_TOOL_XZDEC=OFF",
        "-DXZ_TOOL_LZMADEC=OFF", "-DXZ_TOOL_LZMAINFO=OFF", "-DXZ_NLS=OFF", "-DXZ_DOC=OFF"], apple)
    options = [f"-D{key}=OFF" for key in [
        "ENABLE_TAR", "ENABLE_CPIO", "ENABLE_CAT", "ENABLE_UNZIP", "ENABLE_TEST",
        "ENABLE_OPENSSL", "ENABLE_MBEDTLS", "ENABLE_NETTLE", "ENABLE_LIBB2", "ENABLE_LZ4",
        "ENABLE_LZO", "ENABLE_ZSTD", "ENABLE_BZip2", "ENABLE_LIBXML2", "ENABLE_BSDXML",
        "ENABLE_EXPAT", "ENABLE_WIN32_XMLLITE", "ENABLE_PCREPOSIX", "ENABLE_PCRE2POSIX",
        "ENABLE_XATTR", "ENABLE_ACL", "ENABLE_WERROR"]]
    options += ["-DENABLE_ZLIB=ON", "-DENABLE_LZMA=ON", "-DZLIB_USE_STATIC_LIBS=ON",
                "-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE", f"-DIA_SAFETY_PATCH_SHA256={patch_digest}"]
    configure_build(sources["libarchive"], build / "libarchive", prefix, options, apple)
    return prefix


def build_bridge(prefix: pathlib.Path, label: str, side: bool, apple=None) -> pathlib.Path:
    name = "sideload" if side else "appstore"
    build = ROOT / "Build" / "native" / label / name
    options = [f"-DIA_SIDELOAD={'ON' if side else 'OFF'}", f"-DIA_SHARED={'OFF' if apple else 'ON'}",
               "-DZLIB_USE_STATIC_LIBS=ON"]
    # The wrapper's sources change often; always allow CMake to update it.
    stamp = build / ".iarchiver-built"
    if stamp.exists():
        stamp.unlink()
    configure_build(ROOT / "Native", build, prefix / name, options + [f"-DCMAKE_PREFIX_PATH={prefix}"], apple)
    return build


def build_apple(sources: dict, simulator_only: bool) -> None:
    if platform.system() != "Darwin":
        raise RuntimeError("iOS builds require macOS with Xcode and its public iOS SDK")
    slices = [("iphonesimulator", "arm64")]
    if not simulator_only:
        slices.insert(0, ("iphoneos", "arm64"))
    outputs: dict[str, dict[str, list[pathlib.Path]]] = {"appstore": {}, "sideload": {}}
    for sdk, arch in slices:
        label = f"{sdk}-{arch}"
        prefix = build_dependencies(sources, label, (sdk, arch))
        for side in [False, True]:
            variant = "sideload" if side else "appstore"
            bridge = build_bridge(prefix, label, side, (sdk, arch))
            combined = bridge / "libArchiveCoreCombined.a"
            libraries = [bridge / "libArchiveCore.a", prefix / "lib" / "libarchive.a",
                         prefix / "lib" / "liblzma.a", prefix / "lib" / "libz.a"]
            run(["xcrun", "--sdk", sdk, "libtool", "-static", "-o", str(combined)] + libraries, f"{label}-{variant}-combine")
            outputs[variant].setdefault(sdk, []).append(combined)
    for variant, platforms in outputs.items():
        output = ROOT / "Build" / "Apple" / f"ArchiveCore-{variant}.xcframework"
        output.parent.mkdir(parents=True, exist_ok=True)
        args = ["xcodebuild", "-create-xcframework"]
        for sdk, libraries in platforms.items():
            universal = output.parent / f"{variant}-{sdk}.a"
            run(["xcrun", "lipo", "-create"] + libraries + ["-output", str(universal)], f"{variant}-{sdk}-universal")
            args += ["-library", str(universal), "-headers", str(ROOT / "Native" / "include")]
        if output.exists():
            # Only remove the exact generated framework under this repository's Build/Apple.
            if output.resolve().parent != (ROOT / "Build" / "Apple").resolve():
                raise RuntimeError("Unsafe output path")
            shutil.rmtree(output)
        run(args + ["-output", str(output)], f"{variant}-xcframework")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apple", action="store_true")
    parser.add_argument("--simulator-only", action="store_true")
    options = parser.parse_args()
    sources = bootstrap()
    if options.apple:
        build_apple(sources, options.simulator_only)
    else:
        prefix = build_dependencies(sources, "host")
        for side in [False, True]:
            build_bridge(prefix, "host", side)
    print("Native builds completed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Build error: {error}", file=sys.stderr)
        sys.exit(1)
