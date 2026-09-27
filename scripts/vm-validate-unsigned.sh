#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 scripts/ci-version.py check

build_root="$PWD/.build/vm"
derived_data="$build_root/DerivedData"
unsigned_dir="$build_root/unsigned"
log_dir="$build_root/logs"
counter_file="$build_root/last-build-number"
mkdir -p "$unsigned_dir" "$log_dir"

if [[ -n "${VM_BUILD_NUMBER:-}" ]]; then
  build_number="$VM_BUILD_NUMBER"
elif [[ -s "$counter_file" ]]; then
  build_number="$(( $(<"$counter_file") + 1 ))"
else
  build_number=9001
fi

if [[ ! "$build_number" =~ ^[0-9]+$ ]] || (( build_number < 1 )); then
  echo "VM_BUILD_NUMBER must be a positive integer." >&2
  exit 2
fi
printf '%s\n' "$build_number" > "$counter_file"

short_sha="$(git rev-parse --short=8 HEAD)"
dirty_suffix=""
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  dirty_suffix="-dirty"
fi

common=(
  -project FogWalk.xcodeproj
  -scheme FogWalk
  -destination 'generic/platform=iOS'
  -derivedDataPath "$derived_data"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
  # Xcode 26.3 can deadlock two concurrent AssetCatalogSimulatorAgent handshakes
  # in this VM. The app does not use generated Swift asset symbols.
  ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO
)

echo "Toolchain"
xcodebuild -version
echo "iPhoneOS SDK $(xcrun --sdk iphoneos --show-sdk-version)"
echo "Build $build_number from $short_sha$dirty_suffix"
echo "Simulator execution is intentionally skipped."

xcodebuild analyze \
  "${common[@]}" \
  -configuration Debug \
  2>&1 | tee "$log_dir/analyze-build${build_number}.log"

xcodebuild build-for-testing \
  "${common[@]}" \
  -configuration Debug \
  2>&1 | tee "$log_dir/test-compile-build${build_number}.log"

archive="$build_root/FogWalk-build${build_number}.xcarchive"
if [[ -e "$archive" ]]; then
  echo "Archive already exists: $archive" >&2
  exit 3
fi

xcodebuild archive \
  "${common[@]}" \
  -configuration Release \
  -archivePath "$archive" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee "$log_dir/archive-build${build_number}.log"

app="$archive/Products/Applications/FogWalk.app"
test -f "$app/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")"
xcrun lipo "$app/$executable" -verify_arch arm64

if codesign -d "$app" > "$log_dir/codesign-build${build_number}.log" 2>&1; then
  echo "Expected an unsigned app, but a code signature is present." >&2
  exit 4
fi
test ! -e "$app/embedded.mobileprovision"
test -f "$app/Assets.car"

artifact_name="FogWalk-${version}-build${build_number}-${short_sha}${dirty_suffix}-vm-unsigned"
ipa="$unsigned_dir/$artifact_name.ipa"
if [[ -e "$ipa" ]]; then
  echo "IPA already exists: $ipa" >&2
  exit 5
fi

stage="$(mktemp -d "$build_root/ipa-stage.XXXXXX")"
cleanup() {
  if [[ -n "${stage:-}" && "$stage" == "$build_root/ipa-stage."* ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/FogWalk.app"
(cd "$stage" && /usr/bin/zip -qry "$ipa" Payload)

python3 - "$ipa" "$short_sha$dirty_suffix" <<'PY'
import hashlib
import json
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
source = sys.argv[2]
with zipfile.ZipFile(ipa) as package:
    assert package.testzip() is None, "Corrupt IPA"
    names = package.namelist()
    info = plistlib.loads(package.read("Payload/FogWalk.app/Info.plist"))
    assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
    assert info["CFBundleIdentifier"] == "com.citywalk.FogWalkDemo"
    assert "Payload/FogWalk.app/Assets.car" in names
    assert any(Path(name).name.startswith("AppIcon") and name.endswith(".png") for name in names)
    assert not any("_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names)

digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_suffix(".ipa.sha256").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
metadata = {
    "file": ipa.name,
    "sha256": digest,
    "source": source,
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "minimum_ios": info["MinimumOSVersion"],
    "bundle_identifier": info["CFBundleIdentifier"],
    "platform": info["CFBundleSupportedPlatforms"],
    "architecture": ["arm64"],
    "signed": False,
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "iphoneos_sdk": subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True
    ).strip(),
    "validation": {
        "analyze": "passed",
        "test_bundle_compile": "passed",
        "test_execution": "not_run_without_simulator_or_device",
        "release_archive": "passed",
        "asset_catalog": "compiled_by_current_xcode",
    },
    "vm_workaround": {
        "asset_symbol_generation": False,
        "reason": "Avoid concurrent AssetCatalogSimulatorAgent handshake deadlock in Xcode 26.3 VM",
    },
}
ipa.with_suffix(".build-info.json").write_text(
    json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps(metadata, ensure_ascii=False, indent=2))
PY

echo "IPA: $ipa"
echo "SHA-256: $ipa.sha256"
echo "Build info: ${ipa%.ipa}.build-info.json"
