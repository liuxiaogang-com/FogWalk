#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build

xcrun simctl list devices available -j > .build/simulators.json
python3 - <<'PY'
import json
from pathlib import Path
devices = json.loads(Path('.build/simulators.json').read_text())['devices']
for runtime in sorted(devices, reverse=True):
    if '.iOS-' not in runtime or int(runtime.split('.iOS-', 1)[1].split('-')[0]) < 26:
        continue
    for device in devices[runtime]:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            Path('.build/test-simulator-id').write_text(device['udid'])
            Path('.build/test-simulator-state').write_text(device['state'])
            print(f"Selected {device['name']}: {runtime} / {device['udid']}")
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator with iOS 26 or later')
PY
device_id="$(cat .build/test-simulator-id)"
echo "$(date -u +%FT%TZ) Request simulator boot"
if [[ "$(cat .build/test-simulator-state)" != "Booted" ]]; then
  xcrun simctl boot "$device_id"
fi
# Boot continues in CoreSimulator while the next step builds the test host.
