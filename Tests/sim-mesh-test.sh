#!/usr/bin/env bash
# End-to-end mesh test on iOS simulators, using the real MultipeerConnectivity stack.
#
#   Alice <-> Bob   group "ci"; then Bob relaunches in group "other" and must not reconnect.
#
# Checks: discovery + encrypted session, sealed+signed hello handshake, chat both ways, SOS flood, group isolation. Two simulators is what a free
# GitHub runner can hold; multi-hop routing is covered by Tests/RelaySimulation,
# which runs the same MeshRouter code.
set -uo pipefail

APP="$1"                      # path to NoBars.app (Debug, iphonesimulator)
OUT="${2:-sim-out}"
BID=com.swastik.nobars
NAMES="Alice Bob"
mkdir -p "$OUT"
udid() { eval echo "\$U_$1"; }

# Hard timeout for simulator commands (macOS has no `timeout`).
t() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

# Use simulators that ship with the runner image instead of creating new ones.
POOL=$(xcrun simctl list devices available | grep -E "^ +iPhone" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -2)
[ "$(echo "$POOL" | wc -l | tr -d ' ')" = 2 ] || { echo "need 2 iPhone simulators"; xcrun simctl list devices available; exit 1; }
i=0; for u in $POOL; do set -- $NAMES; shift $i; eval "U_$1=$u"; i=$((i+1)); done
for n in $NAMES; do
  u=$(udid $n); echo "booting $n ($u)"
  t 60 xcrun simctl shutdown "$u" 2>/dev/null
  booted=0
  for attempt in 1 2; do
    t 120 xcrun simctl boot "$u" || echo "boot cmd returned non-zero for $n"
    if t 300 xcrun simctl bootstatus "$u" -b >/dev/null; then booted=1; break; fi
    # Hosted macOS runners sometimes wedge a second simulator; wipe it and try once more.
    echo "$n stuck booting (attempt $attempt), erasing and retrying"
    t 60 xcrun simctl shutdown "$u" 2>/dev/null; t 120 xcrun simctl erase "$u" 2>/dev/null
  done
  [ "$booted" = 1 ] || { echo "$n never finished booting"; exit 1; }
  echo "$n booted"
done
echo "letting simulators settle"; sleep 45

stream() { xcrun simctl spawn "$(udid $1)" log stream --level info --style compact \
  --predicate 'subsystem == "com.swastik.nobars"' > "$OUT/$2.log" 2>&1 & }

for n in $NAMES; do
  u=$(udid $n)
  t 180 xcrun simctl install "$u" "$APP" || { echo "install failed on $n"; exit 1; }
  xcrun simctl privacy "$u" grant location-always "$BID" || true
  xcrun simctl privacy "$u" grant microphone "$BID" || true
  xcrun simctl location "$u" set 28.4744,77.5040 || true
  stream $n $n
done
sleep 3

launch() { # name group only [send]
  local args=(-nobars.onboarded YES -nobars.walkthroughDone YES -nobars.displayName "$1" -nobars.groupCode "$2" -meshTestOnly "$3")
  if [ -n "${4:-}" ]; then args+=(-meshTestSend "$4"); fi
  if [ -n "${5:-}" ]; then args+=(-meshTestSOS YES); fi
  t 300 xcrun simctl launch "$(udid $1)" "$BID" "${args[@]}" && return 0
  echo "launch of $1 timed out, retrying"
  t 300 xcrun simctl launch "$(udid $1)" "$BID" "${args[@]}" || echo "launch of $1 FAILED"
}
launch Bob   ci Alice "hi from bob"
launch Alice ci Bob   "hello from alice" sos

echo "waiting for mesh + messages..."; sleep 60
# SOS fires from Alice right after her chat messages (simctl openurl would
# stop on a system "Open in NoBars?" prompt that real taps don't show).
echo "waiting for SOS..."; sleep 25
for n in $NAMES; do t 30 xcrun simctl io "$(udid $n)" screenshot "$OUT/$n.png" >/dev/null 2>&1 || true; done

echo "group isolation: relaunching Bob in group 'other'"
t 60 xcrun simctl terminate "$(udid Bob)" "$BID"; sleep 3
stream Bob Bob-other
launch Bob other Alice
sleep 30

kill $(jobs -p) 2>/dev/null; sleep 1

fail=0
check() { if grep -qE "$3" "$OUT/$2.log"; then r=PASS; else r=FAIL; fi
  if [ "$1" = not ]; then [ $r = PASS ] && r=FAIL || r=PASS; fi
  echo "$r  $4"; [ $r = FAIL ] && fail=1; return 0; }
check is  Bob       "Trusted Alice"                 "Encrypted signed hello: Bob pins Alice's key"
check is  Alice     "Trusted Bob"                   "Encrypted signed hello: Alice pins Bob's key"
check is  Bob       "Connected: Alice"              "Bob connects to Alice"
check is  Alice     "Connected: Bob"                "Alice connects to Bob"
check is  Bob       "Message from Alice via Alice"  "Bob receives Alice's chat"
check is  Alice     "Message from Bob via Bob"      "Alice receives Bob's chat"
check is  Alice     "SOS started"                   "Alice starts SOS"
check is  Bob       "SOS from Alice"                "Bob gets Alice's SOS location flood"
check not Bob-other "Connected:"                    "Different group never connects"

for f in Alice Bob Bob-other; do echo "--- $f"; grep -vE "^Filtering|^Timestamp" "$OUT/$f.log" | tail -15; done
for n in $NAMES; do t 60 xcrun simctl shutdown "$(udid $n)" >/dev/null 2>&1; done
[ $fail = 0 ] && echo "ALL MESH CHECKS PASSED" > "$OUT/RESULT"
exit $fail
