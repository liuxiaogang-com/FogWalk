#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build

# Discover an available iPhone with an iOS 26+ runtime instead of a personal UDID.
xcrun simctl list devices available -j > .build/simulators.json
device_id="$(python3 - <<'PY'
import json
with open(".build/simulators.json") as stream:
    devices = json.load(stream)["devices"]
for runtime in sorted(devices, reverse=True):
    if ".iOS-" not in runtime:
        continue
    major = int(runtime.split(".iOS-", 1)[1].split("-")[0])
    if major < 26:
        continue
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator with iOS 26 or later")
PY
)"

xcodebuild test \
  -project FogWalk.xcodeproj \
  -scheme FogWalk \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" \
  -destination-timeout 180 \
  -derivedDataPath .build/SimulatorDerivedData \
  -resultBundlePath ".build/Tests.xcresult" \
  -parallel-testing-enabled NO \
  -skip-testing:FogWalkTests/FogWalkTests/testFullDemoImportParsesAndDeduplicatesAllSources \
  -skip-testing:FogWalkTests/FogWalkTests/testDayPresentationHasVisiblePathsAtExplicitHistoricalDate \
  -skip-testing:FogWalkTests/StartupPerformanceTests/testFullLibraryStartupBenchmark \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee .build/test.log
