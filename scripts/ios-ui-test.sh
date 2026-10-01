#!/usr/bin/env bash
# Run one of the showcase's scripted UI tests (examples/showcase/web/uitest.js)
# in a booted iOS simulator and follow it through the app's log:
#
#   scripts/ios-ui-test.sh <udid> <bundle-id> <test> <timeout-s> [out-dir]
#
# The app is launched with `--ui-test <test>`; its stdout/stderr go to
# <out-dir>/ui-<test>.log, printed here as they arrive. Each "ui-test:
# screenshot <name>" line gets a screenshot (<out-dir>/shot-<test>-<name>.png).
# Exits 0 on "ui-test: done ok", 1 on "ui-test: FAIL ...", the app exiting
# (its crash report is printed) or the timeout. The app keeps running.
set -u
udid=$1 bundle=$2 name=$3 timeout=$4 out=${5:-.}
# Absolute: simctl hands --stdout to the simulator, which refuses the whole
# launch ("denied by service delegate (SBMainWorkspace)") over a relative path.
out=$(cd "$out" && pwd)
logf="$out/ui-$name.log"
: > "$logf"
# A launch right after terminating the previous instance is refused ("The
# request was denied by service delegate (SBMainWorkspace)") while that one
# is still going away: wait, and retry.
# The test's name reaches the app as `--ui-test <name>` and as
# ORIEL_UI_TEST (simctl passes SIMCTL_CHILD_* variables on).
xcrun simctl terminate "$udid" "$bundle" 2>&1 | sed 's/^/[runner] terminate: /' || true
pid=
for attempt in 1 2 3 4 5; do
  sleep 3
  if launched=$(SIMCTL_CHILD_ORIEL_UI_TEST="$name" xcrun simctl launch --terminate-running-process --stdout="$logf" --stderr="$logf" "$udid" "$bundle" --ui-test "$name" 2>&1); then
    echo "$launched (attempt $attempt)"
    pid=${launched##*: }
    break
  fi
  echo "[runner] launch attempt $attempt failed: $launched"
done
if [ -z "$pid" ]; then
  echo "[runner] the app would not launch"
  exit 1
fi

seen=" "
shots() {
  for s in $(grep -ao 'ui-test: screenshot [A-Za-z0-9_-]*' "$logf" | awk '{print $3}'); do
    case "$seen" in
      *" $s "*) ;;
      *) xcrun simctl io "$udid" screenshot "$out/shot-$name-$s.png" >/dev/null 2>&1
         echo "[runner] screenshot shot-$name-$s.png"
         seen="$seen$s " ;;
    esac
  done
}

printed=0
follow() {
  local n
  n=$(wc -l < "$logf")
  if [ "$n" -gt "$printed" ]; then
    sed -n "$((printed + 1)),${n}p" "$logf"
    printed=$n
  fi
}

status=1
end=$((SECONDS + timeout))
while :; do
  follow
  shots
  # A screenshot can take seconds: take the ones asked for meanwhile.
  if grep -aq 'ui-test: done ok' "$logf"; then shots; status=0; break; fi
  if grep -aq 'ui-test: FAIL' "$logf"; then sleep 2; shots; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[runner] the app (pid $pid) exited"
    # The system's last words on it (a crash report takes a few seconds).
    xcrun simctl spawn "$udid" log show --last 2m --style compact \
      --predicate "process == \"oriel-showcase\" OR eventMessage CONTAINS \"$bundle\"" 2>/dev/null | tail -60
    sleep 10
    ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -5
    report=$(ls -t ~/Library/Logs/DiagnosticReports/*oriel-showcase* 2>/dev/null | head -1)
    [ -n "$report" ] && head -c 20000 "$report"
    break
  fi
  if [ "$SECONDS" -ge "$end" ]; then
    echo "[runner] timed out after ${timeout}s"
    xcrun simctl io "$udid" screenshot "$out/shot-$name-timeout.png" >/dev/null 2>&1
    break
  fi
  sleep 1
done
follow
exit $status
