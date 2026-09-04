#!/bin/bash
# Real Core Location delivery in an isolated iOS Simulator, not delegate injection.
# Usage: bash scripts/run-location-journey.sh SIMULATOR_UUID OUTPUT_DIRECTORY
set -euo pipefail
qa_device="${1:?Simulator UUID required}"
qa_output="${2:?Output directory required}"
qa_bundle="com.citywalk.FogWalkDemo"
mkdir -p "$qa_output"
qa_output="$(cd "$qa_output" && pwd)"
qa_container="$(xcrun simctl get_app_container "$qa_device" "$qa_bundle" data)"
qa_database="$qa_container/Library/Application Support/FogWalk/Recording/recordings.sqlite"

cleanup() { xcrun simctl location "$qa_device" clear >/dev/null 2>&1 || true; }
trap cleanup EXIT
snapshot() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
    sqlite3 -readonly -header -column "$qa_database" \
      'select mode,context,count(*) points,round(max(time)-min(time),1) span_s,round(min(accuracy),1) best_accuracy,round(max(accuracy),1) worst_accuracy from points group by mode,context;'
}
count() { sqlite3 -readonly "$qa_database" "select count(*) from points where mode='$1';"; }
count_context() { sqlite3 -readonly "$qa_database" "select count(*) from points where mode='$1' and context='$2';"; }
launch_recording() {
    xcrun simctl terminate "$qa_device" "$qa_bundle" >/dev/null 2>&1 || true
    xcrun simctl launch --stdout="$qa_output/$2.stdout.log" --stderr="$qa_output/$2.stderr.log" \
      "$qa_device" "$qa_bundle" -recording-enabled-v1 YES -recording-mode-v1 "$1" -motion-assistance-v1 NO --open-recording
}
background() { xcrun simctl launch "$qa_device" com.apple.Preferences; }

xcrun simctl privacy "$qa_device" grant location-always "$qa_bundle"
xcrun simctl location "$qa_device" set 31.2300,121.4700
launch_recording 正常 normal
sleep 3
snapshot normal_baseline
qa_normal_before="$(count 正常)"
qa_normal_fg_before="$(count_context 正常 foreground)"
qa_normal_bg_before="$(count_context 正常 background)"
# About 75 m at walking speed; start returns immediately while Simulator moves.
xcrun simctl location "$qa_device" start --speed=1.5 --interval=1 31.2300,121.4700 31.230676,121.4700
sleep 20
snapshot normal_foreground
background
sleep 32
snapshot normal_first_leg
qa_normal_arrival="$(count 正常)"
xcrun simctl location "$qa_device" set 31.230676,121.4700
for qa_step in 1 2 3 4 5; do
    sleep 25
    snapshot "stationary_${qa_step}"
done
qa_normal_stopped="$(count 正常)"
xcrun simctl location "$qa_device" start --speed=1.5 --interval=1 31.230676,121.4700 31.231352,121.4700
sleep 25
snapshot normal_resume_midway
sleep 27
snapshot normal_resume_complete
qa_normal_after="$(count 正常)"
test "$qa_normal_arrival" -gt "$qa_normal_before"
test "$qa_normal_after" -gt "$qa_normal_stopped"
test "$((qa_normal_stopped-qa_normal_arrival))" -le 1
test "$(count_context 正常 foreground)" -gt "$qa_normal_fg_before"
test "$(count_context 正常 background)" -gt "$qa_normal_bg_before"

# Saver: about 135 m, then switch out of the app while the route continues.
launch_recording 省电 saver
sleep 3
qa_saver_before="$(count 省电)"
qa_saver_fg_before="$(count_context 省电 foreground)"
qa_saver_bg_before="$(count_context 省电 background)"
xcrun simctl location "$qa_device" start --speed=1.5 --interval=1 31.231352,121.4700 31.232570,121.4700
sleep 45
snapshot saver_foreground
background
sleep 15
snapshot saver_background_midway
sleep 32
snapshot saver_complete
qa_saver_after="$(count 省电)"
test "$qa_saver_after" -gt "$qa_saver_before"
test "$(count_context 省电 foreground)" -gt "$qa_saver_fg_before"
test "$(count_context 省电 background)" -gt "$qa_saver_bg_before"

xcrun simctl location "$qa_device" clear
qa_before_restart="$(sqlite3 -readonly "$qa_database" 'select count(*) from points;')"
xcrun simctl terminate "$qa_device" "$qa_bundle"
# No developer recording override here: verify the stored journal survives a real process restart.
xcrun simctl launch --stdout="$qa_output/relaunch.stdout.log" --stderr="$qa_output/relaunch.stderr.log" "$qa_device" "$qa_bundle"
sleep 5
qa_after_restart="$(sqlite3 -readonly "$qa_database" 'select count(*) from points;')"
test "$qa_before_restart" -eq "$qa_after_restart"
xcrun simctl io "$qa_device" screenshot "$qa_output/relaunch-map.png"
snapshot final
printf '\nPASS normal_movement=%s normal_stationary_added=%s normal_resumed=%s saver_added=%s retained_after_restart=%s\n' \
  "$((qa_normal_arrival-qa_normal_before))" "$((qa_normal_stopped-qa_normal_arrival))" \
  "$((qa_normal_after-qa_normal_stopped))" "$((qa_saver_after-qa_saver_before))" "$qa_after_restart"
