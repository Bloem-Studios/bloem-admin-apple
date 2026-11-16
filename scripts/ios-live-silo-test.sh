#!/usr/bin/env bash
# Run the gated live test (BloemAdminUITests/SiloServerLiveUITests) against a real Silo server on the Mac's simulators.
#
#   scripts/ios-live-silo-test.sh [credentials-file]
#
# The credentials file is KEY=value lines with URL_MAC (the address the Mac's simulators reach), ADMIN_USER and
# ADMIN_PASSWORD. Use a throwaway sandbox server, never a real one. MAC_HOST is the ssh host of the Mac that runs
# the simulator; SILO_LIVE_CREDENTIALS may name the file instead of the argument; SIM_DESTINATION is the simulator's
# UDID (`xcrun simctl list devices`). The values are handed to the Mac on the ssh
# connection's standard input, never in a command line, and exported there as TEST_RUNNER_SILO_LIVE_URL / _USER /
# _PASSWORD, which xcodebuild passes on to the test runner as SILO_LIVE_*. Nothing is written to the repository except
# the screenshots (docs/screenshots/silo-server/). Run it from the root of an iOS checkout.
set -euo pipefail
SRC="$(pwd)"
[ -f "$SRC/project.yml" ] || { echo "run this from the root of an iOS checkout (no project.yml here)"; exit 2; }
MAC_HOST="${MAC_HOST:?set MAC_HOST to the ssh host of the Mac that runs the simulator}"
CREDS="${1:-${SILO_LIVE_CREDENTIALS:?pass a credentials file or set SILO_LIVE_CREDENTIALS}}"
[ -r "$CREDS" ] || { echo "cannot read $CREDS"; exit 2; }
value() { grep -E "^$1=" "$CREDS" | head -1 | cut -d= -f2-; }
URL="$(value URL_MAC)"; USER_NAME="$(value ADMIN_USER)"; PASS="$(value ADMIN_PASSWORD)"
[ -n "$URL" ] && [ -n "$USER_NAME" ] && [ -n "$PASS" ] || { echo "URL_MAC, ADMIN_USER and ADMIN_PASSWORD must be set in $CREDS"; exit 2; }

NAME="wt-$(basename "$SRC")"
LOG="/tmp/ios-live-silo-${NAME}-$(date +%Y%m%d-%H%M%S)-$$.log"
echo "log: $LOG"

DEST="${SIM_DESTINATION:?set SIM_DESTINATION to the UDID of an iPhone simulator on the Mac}"
echo "simulator: $DEST"

rsync -az --delete --exclude .git --exclude '*.xcodeproj' --exclude DerivedData --exclude .dd \
  ./ "${MAC_HOST}:projects/${NAME}/"

set +e
printf '%s\n%s\n%s\n' "$URL" "$USER_NAME" "$PASS" | ssh -o ServerAliveInterval=30 "${MAC_HOST}" \
  "export PATH=/opt/homebrew/bin:\$PATH; IFS= read -r U; IFS= read -r N; IFS= read -r P; \
   export TEST_RUNNER_SILO_LIVE_URL=\"\$U\" TEST_RUNNER_SILO_LIVE_USER=\"\$N\" TEST_RUNNER_SILO_LIVE_PASSWORD=\"\$P\"; \
   rm -rf /tmp/silo-server-shots; mkdir -p /tmp/silo-server-shots; \
   cd ~/projects/${NAME} && xcodegen generate --quiet && \
   xcodebuild test -project BloemAdmin.xcodeproj -scheme BloemAdmin -destination id=$DEST -derivedDataPath .dd \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -only-testing:BloemAdminUITests/SiloServerLiveUITests" >"$LOG" 2>&1
STATUS=$?
set -e

mkdir -p docs/screenshots/silo-server
rsync -az "${MAC_HOST}:/tmp/silo-server-shots/" docs/screenshots/silo-server/ || echo "no screenshots copied"
if grep -qF -- "$PASS" "$LOG"; then echo "WARNING: the log contains the password; delete $LOG"; fi

grep -E "error:|: error|Test case '[^']*' (failed|passed|skipped)|\*\* (BUILD|TEST)|XCTSkip|Executed [0-9]+ tests" "$LOG" | sort -u | head -60
[ -f docs/screenshots/silo-server/pages.txt ] && { echo "--- pages"; cat docs/screenshots/silo-server/pages.txt; }
echo "exit=$STATUS"
exit $STATUS
