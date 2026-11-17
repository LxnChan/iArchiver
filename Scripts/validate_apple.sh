#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# An export assignment masks command-substitution errors. Select separately.
selected_xcode="$(python3 Scripts/apple_toolchain.py)"
export DEVELOPER_DIR="$selected_xcode"
export IARCHIVER_XCODE_PATH="$selected_xcode"
mkdir -p Build/logs Build/TestResults

logged() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "Build/logs/$name.log"
}

stage="${1:-all}"
case "$stage" in
  all)
    for child in host-build frameworks native-tests swift-tests apps bundles; do
      bash Scripts/validate_apple.sh "$child"
    done
    python3 Scripts/test_simulators.py
    python3 Scripts/package_apple_artifacts.py
    ;;
  host-build) python3 -u Scripts/build_native.py ;;
  frameworks) python3 -u Scripts/build_native.py --apple ;;
  native-tests) logged native-tests python3 Tests/native/test_archive_core.py ;;
  # SwiftPM's xunit exporter currently emits only the empty Swift Testing suite
  # for this XCTest package. Preserve XCTest's actual per-case log instead.
  swift-tests) logged swift-tests swift test ;;
  apps)
    failed=0
    for variant in AppStore Sideload; do
      for platform in Simulator Device; do
        destination='generic/platform=iOS'
        if [[ "$platform" == Simulator ]]; then destination='generic/platform=iOS Simulator'; fi
        if ! logged "app-$variant-$platform" xcodebuild -project iArchiver.xcodeproj \
          -scheme "iArchiver-$variant" -configuration Release -destination "$destination" \
          -derivedDataPath "Build/DerivedData-$variant-$platform" \
          -resultBundlePath "Build/TestResults/build-$variant-$platform.xcresult" \
          CODE_SIGNING_ALLOWED=NO build; then
          failed=1
        fi
      done
    done
    exit "$failed"
    ;;
  bundles) logged apple-bundles python3 Scripts/validate_apple_bundle.py ;;
  *) echo "Unknown Apple validation stage: $stage" >&2; exit 2 ;;
esac
