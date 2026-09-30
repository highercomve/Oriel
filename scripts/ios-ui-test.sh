#!/usr/bin/env bash
# Run one of the showcase's scripted UI tests (examples/showcase/web/uitest.js)
# in a booted iOS simulator and follow it through the app's log:
#
#   scripts/ios-ui-test.sh <udid> <bundle-id> <test> <timeout-s> [out-dir]
#
# The app is launched with `--ui-test <test>`; its stdout/stderr go to
# <out-dir>/ui-<test>.log. Each "ui-test: screenshot <name>" line in it gets
# a screenshot (<out-dir>/shot-<test>-<name>.png). Exits 0 on "ui-test: done
# ok", 1 on "ui-test: FAIL ..." or the timeout. The app keeps running.
set -u
udid=$1 bundle=$2 name=$3 timeout=$4 out=${5:-.}
logf="$out/ui-$name.log"
: > "$logf"
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl launch --stdout="$logf" --stderr="$logf" "$udid" "$bundle" --ui-test "$name"

seen=" "
shots() {
  for s in $(grep -ao 'ui-test: screenshot [A-Za-z0-9_-]*' "$logf" | awk '{print $3}'); do
    case "$seen" in
      *" $s "*) ;;
      *) xcrun simctl io "$udid" screenshot "$out/shot-$name-$s.png" >/dev/null 2>&1
         echo "screenshot: shot-$name-$s.png"
         seen="$seen$s " ;;
    esac
  done
}

status=1
end=$((SECONDS + timeout))
while [ "$SECONDS" -lt "$end" ]; do
  shots
  if grep -aq 'ui-test: done ok' "$logf"; then status=0; break; fi
  if grep -aq 'ui-test: FAIL' "$logf"; then sleep 2; shots; break; fi
  sleep 1
done
[ "$SECONDS" -ge "$end" ] && echo "timed out after ${timeout}s"
echo "---- ui-$name.log"
cat "$logf"
exit $status
