#!/usr/bin/env bash
# Captures real screenshots of the app for the website, on two simulators
# meshed together (Arjun and Kabir at a festival, Kabir sends SOS).
set -uo pipefail
APP="$1"; OUT="${2:-shots}"; BID=com.swastik.nobars
mkdir -p "$OUT"
t() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
POOL=$(xcrun simctl list devices available | grep -E "^ +iPhone" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -2)
A=$(echo "$POOL" | sed -n 1p); B=$(echo "$POOL" | sed -n 2p)
for u in $A $B; do
  ok=0
  for attempt in 1 2; do
    t 60 xcrun simctl shutdown "$u" 2>/dev/null
    t 180 xcrun simctl boot "$u"
    if t 420 xcrun simctl bootstatus "$u" -b >/dev/null; then ok=1; break; fi
    echo "boot retry for $u"
  done
  [ $ok = 1 ] || { echo "could not boot $u"; exit 1; }
done
sleep 40
for u in $A $B; do
  t 180 xcrun simctl install "$u" "$APP" || exit 1
  xcrun simctl privacy "$u" grant location-always "$BID" || true
  xcrun simctl privacy "$u" grant microphone "$BID" || true
  xcrun simctl status_bar "$u" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 0 --wifiBars 0 --operatorName "" || true
  xcrun simctl ui "$u" appearance dark || true
done
xcrun simctl location "$A" set 28.47440,77.50400
xcrun simctl location "$B" set 28.47520,77.50510
xcrun simctl spawn "$A" log stream --style compact --predicate 'subsystem == "com.swastik.nobars"' > "$OUT/arjun.log" 2>&1 &
xcrun simctl spawn "$B" log stream --style compact --predicate 'subsystem == "com.swastik.nobars"' > "$OUT/kabir.log" 2>&1 &
sleep 3

common=(-nobars.onboarded YES -nobars.walkthroughDone YES -nobars.groupCode fest24)
t 300 xcrun simctl launch "$B" "$BID" "${common[@]}" -nobars.displayName Kabir -meshTestOnly Arjun \
  -meshTestScript "lost you guys near the food stalls|no signal at all here lol|ok sharing my location" -meshTestSOS YES
t 300 xcrun simctl launch "$A" "$BID" "${common[@]}" -nobars.displayName Arjun -meshTestOnly Kabir \
  -meshTestScriptDelay 4 -meshTestScript "we're at the main stage|wait, where are you?" \
  -meshTestTabs 0,1,2 -meshTestTabsAfterSOS YES

seen() { xcrun simctl spawn "$A" log show --last 5m --style compact \
  --predicate "subsystem == \"com.swastik.nobars\" AND eventMessage CONTAINS \"$1\"" 2>/dev/null | grep -q "$1"; }
shot_on() { # marker, device, file
  for i in $(seq 1 120); do seen "$1" && break; sleep 2; done
  sleep 3; t 30 xcrun simctl io "$2" screenshot "$OUT/$3.png"; echo "shot $3"
}
shot_on "SHOT tab 0" "$A" home
t 30 xcrun simctl io "$B" screenshot "$OUT/kabir-home.png"; echo "shot kabir-home"
shot_on "SHOT tab 1" "$A" chat
shot_on "SHOT tab 2" "$A" map

# Onboarding and walkthrough on a fresh launch
t 60 xcrun simctl terminate "$B" "$BID"; sleep 2
t 300 xcrun simctl launch "$B" "$BID" -nobars.onboarded NO -nobars.walkthroughDone NO -nobars.displayName "" -nobars.groupCode ""
sleep 9; t 30 xcrun simctl io "$B" screenshot "$OUT/onboarding.png"; echo "shot onboarding"
t 60 xcrun simctl terminate "$B" "$BID"; sleep 2
t 300 xcrun simctl launch "$B" "$BID" -nobars.onboarded YES -nobars.walkthroughDone NO -nobars.displayName Kabir -nobars.groupCode fest24
sleep 9; t 30 xcrun simctl io "$B" screenshot "$OUT/walkthrough.png"; echo "shot walkthrough"

kill $(jobs -p) 2>/dev/null
ls -la "$OUT"
