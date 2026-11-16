#!/usr/bin/env bash
# Photograph every page of the app for the quality audit: dark and light, upright and held sideways, at the default
# text size and at a very large one, on an iPhone (or, with IOS_IPAD=1, the iPad). It runs
# BloemAdminUITests/QualityTourUITests on a remote Mac you reach over ssh (MAC_HOST), then copies the PNGs back. TEST_SCRIPT is your own wrapper that
# syncs the checkout to that Mac and runs `xcodebuild test` there, passing its arguments on to xcodebuild.
#
# Needs: MAC_HOST (ssh host of the Mac that runs the simulator) and TEST_SCRIPT (see above).
# Run from the root of a checkout (any worktree):
#   scripts/quality-shots.sh <tag> [out-dir]     # out-dir defaults to docs/screenshots/quality-2026-11-16
#   IOS_IPAD=1 scripts/quality-shots.sh <tag> [out-dir]
#   QUALITY_TEST=BloemAdminUITests/QualityTourUITests/testShellAndServers scripts/quality-shots.sh <tag>   # one group of pages
#
# The tour is gated on /tmp/bloem-admin-quality-shots/phase on the Mac, which this script writes and removes.
# Files are named <screen>-<variant>-<dark|light>.png.
set -euo pipefail
TAG="${1:?usage: scripts/quality-shots.sh <tag> [out-dir]}"
OUT="${2:-docs/screenshots/quality-2026-11-16}"
ROOT="/tmp/bloem-admin-quality-shots"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_HOST="${MAC_HOST:?set MAC_HOST to the ssh host of the Mac that runs the simulator}"
TEST_SCRIPT="${TEST_SCRIPT:?set TEST_SCRIPT to a script that syncs this checkout to the Mac and runs xcodebuild test}"
[ -x "$TEST_SCRIPT" ] || { echo "no test script at $TEST_SCRIPT"; exit 2; }

ssh ${MAC_HOST} "rm -rf ${ROOT} && mkdir -p ${ROOT} && echo ${TAG} > ${ROOT}/phase"
set +e
( cd "$HERE" && "$TEST_SCRIPT" "-only-testing:${QUALITY_TEST:-BloemAdminUITests/QualityTourUITests}" )
STATUS=$?
set -e

mkdir -p "$OUT"
rsync -az "${MAC_HOST}:${ROOT}/${TAG}/" "$OUT/"
ssh ${MAC_HOST} "rm -rf ${ROOT}"
echo "quality screenshots: $(ls "$OUT" | wc -l) in $OUT"
exit $STATUS
