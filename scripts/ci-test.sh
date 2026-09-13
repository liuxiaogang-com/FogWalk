#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
if [[ ! -s .build/test-simulator-id ]]; then
  bash scripts/ci-prepare-simulator.sh
fi
device_id="$(cat .build/test-simulator-id)"
common=(
  -project FogWalk.xcodeproj -scheme FogWalk -configuration Debug
  -destination "platform=iOS Simulator,id=$device_id" -destination-timeout 180
  -derivedDataPath .build/SimulatorDerivedData
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
)

echo "$(date -u +%FT%TZ) Build test host and test bundle" | tee .build/test.log
xcodebuild build-for-testing "${common[@]}" 2>&1 | tee -a .build/test.log
echo "$(date -u +%FT%TZ) Wait for simulator boot" | tee -a .build/test.log
xcrun simctl bootstatus "$device_id" -b 2>&1 | tee .build/simulator-boot.log
echo "$(date -u +%FT%TZ) Start XCTest (without debugger or production homepage)" | tee -a .build/test.log
xcodebuild test-without-building "${common[@]}" \
  -resultBundlePath .build/Tests.xcresult \
  -parallel-testing-enabled NO \
  -skip-testing:FogWalkTests/FogWalkTests/testFullDemoImportParsesAndDeduplicatesAllSources \
  -skip-testing:FogWalkTests/FogWalkTests/testDayPresentationHasVisiblePathsAtExplicitHistoricalDate \
  -skip-testing:FogWalkTests/StartupPerformanceTests/testFullLibraryStartupBenchmark \
  2>&1 | tee -a .build/test.log
echo "$(date -u +%FT%TZ) XCTest completed" | tee -a .build/test.log
