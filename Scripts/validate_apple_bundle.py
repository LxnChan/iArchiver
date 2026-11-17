"""Inspect actual device products after validate_apple.sh; not a signing/export check."""
import pathlib
import plistlib
import subprocess
from bootstrap import ROOT

for variant, product in [("AppStore", "iArchiver"), ("Sideload", "iArchiver Sideload")]:
    app = ROOT / "Build" / f"DerivedData-{variant}-Device" / "Build" / "Products" / "Release-iphoneos" / (product + ".app")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    result = subprocess.run(["xcrun", "nm", "-gj", str(executable)], capture_output=True, text=True, check=True)
    has_unrar = any(name in result.stdout.splitlines() for name in ["_iarar_open", "_RAROpenArchiveEx"])
    assert has_unrar == (variant == "Sideload"), f"Unexpected linked UnRAR capability: {variant}"
    assert (app / "UnRARLicense.txt").exists() == (variant == "Sideload")
    assert (app / "ThirdPartyNotices.txt").stat().st_size > 1000
    assert (app / "PrivacyInfo.xcprivacy").exists()
    assert info["MinimumOSVersion"] == "18.0"
    assert set(info["UIDeviceFamily"]) == {1, 2}
    assert "com.example" not in info["CFBundleIdentifier"] or not (app / "embedded.mobileprovision").exists(), "Signed release still uses example Bundle ID"
    print(f"PASS: {variant} device product, explicit format variant, privacy/notices, iPhone+iPad, iOS 18 minimum.")
