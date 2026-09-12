#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/unsigned
# CI builds are monotonic and distinct from the migrated local build 6.
build_number="$((1000 + ${GITHUB_RUN_NUMBER:-1}))"
short_sha="$(git rev-parse --short=8 HEAD)"
archive="$PWD/.build/FogWalk.xcarchive"

xcodebuild archive \
  -project FogWalk.xcodeproj \
  -scheme FogWalk \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DeviceDerivedData \
  -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee .build/archive.log

app="$archive/Products/Applications/FogWalk.app"
test -f "$app/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")"
xcrun lipo "$app/$executable" -verify_arch arm64
if codesign -d "$app" > .build/codesign.log 2>&1; then
  echo "Expected an unsigned app, but a code signature is present." >&2
  exit 1
fi
test ! -e "$app/embedded.mobileprovision"

artifact_name="FogWalk-${version}-build${build_number}-${short_sha}-unsigned"
# Use a fresh staging directory and preserve executable permissions in the ZIP.
stage="$(mktemp -d "$PWD/.build/ipa-stage.XXXXXX")"
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/FogWalk.app"
ipa="$PWD/.build/unsigned/$artifact_name.ipa"
(cd "$stage" && /usr/bin/zip -qry "$ipa" Payload)

python3 - "$ipa" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

ipa = Path(sys.argv[1])
with zipfile.ZipFile(ipa) as package:
    assert package.testzip() is None, "Corrupt IPA"
    names = package.namelist()
    info = plistlib.loads(package.read("Payload/FogWalk.app/Info.plist"))
    assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
    assert info["CFBundleIdentifier"] == "com.citywalk.FogWalkDemo"
    assert not any("_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_suffix(".ipa.sha256").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
metadata = {
    "file": ipa.name,
    "sha256": digest,
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "minimum_ios": info["MinimumOSVersion"],
    "bundle_identifier": info["CFBundleIdentifier"],
    "platform": info["CFBundleSupportedPlatforms"],
    "signed": False,
    "run_url": f"{os.environ.get('GITHUB_SERVER_URL', '')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
}
(ipa.parent / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
print(json.dumps(metadata, indent=2))
PY

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "artifact_name=$artifact_name" >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Unsigned iPhone IPA"
    echo "- File: $artifact_name.ipa"
    echo "- Requires iOS 26 or later and re-signing before installation."
    echo "- Three tests requiring private demodata are excluded; other tests must pass."
    echo "- SHA-256 and build provenance are included in the artifact."
  } >> "$GITHUB_STEP_SUMMARY"
fi
