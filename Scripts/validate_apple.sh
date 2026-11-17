#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="$(python3 Scripts/apple_toolchain.py)"
xcodebuild -version
python3 -u Scripts/build_native.py
python3 Tests/native/test_archive_core.py
swift test
python3 -u Scripts/build_native.py --apple
python3 Scripts/generate_project.py
for variant in AppStore Sideload; do
  xcodebuild -project iArchiver.xcodeproj -scheme "iArchiver-$variant" \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "Build/DerivedData-$variant-Simulator" CODE_SIGNING_ALLOWED=NO build
  xcodebuild -project iArchiver.xcodeproj -scheme "iArchiver-$variant" \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "Build/DerivedData-$variant-Device" CODE_SIGNING_ALLOWED=NO build
done
python3 Scripts/validate_apple_bundle.py
