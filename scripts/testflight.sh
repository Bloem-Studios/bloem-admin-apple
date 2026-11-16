#!/usr/bin/env bash
# Build Bloem Admin for iOS and send it to TestFlight.
#
#   scripts/testflight.sh [--check | --no-upload | --unsigned]
#
# Run it on a Mac with Xcode, from a clean checkout of the release tag. With no flag it archives the Release
# configuration, signs it automatically and uploads it to App Store Connect. Nothing in this repository holds a team,
# a key or a profile: they all come from the environment, outside git.
#
# WHAT IT NEEDS (environment variables)
#   BLOEM_ADMIN_TEAM_ID   Your 10-character Apple Developer Team ID (Membership details at developer.apple.com).
#   ASC_KEY_PATH          Path to the App Store Connect API key file, AuthKey_<KEYID>.p8. Keep it outside the checkout.
#   ASC_KEY_ID            The key's ID (10 characters), shown next to the key in App Store Connect.
#   ASC_ISSUER_ID         The issuer ID (a UUID) at the top of Users and Access > Integrations > App Store Connect API.
#   The key needs the App Manager role (or Admin). With it Xcode creates and renews the signing certificate and the
#   provisioning profiles of the app and both extensions by itself, so no Xcode account and no manual profile is needed.
#
# OPTIONAL
#   RELEASE_ENV_FILE      A file of KEY=value lines (outside the checkout) the script reads first, for example
#                         ~/.config/bloem-admin/release.env, mode 0600. Variables already set win.
#   MARKETING_VERSION     Override the version (1.2.3). By default it comes from the git tag on HEAD (see below).
#   BUILD_NUMBER          Override the build number. By default it is the UTC time as YYYYMMDDHHMM.
#   BUILD_DIR             Where the archive, the export and the logs go (default: build/ in the checkout, git-ignored).
#
# VERSIONS
#   Marketing version: the release tag on HEAD, `v<major>.<minor>[.<patch>]`, for example v1.0.0 gives 1.0.0.
#   Create the tag yourself (`git tag v1.0.0`); this script never creates or pushes a tag. It stops when HEAD has no
#   such tag, unless MARKETING_VERSION is set.
#   Build number: the UTC time, so each run is higher than the last and App Store Connect accepts it. Two builds in the
#   same minute collide: wait a minute, or set BUILD_NUMBER. The app and both extensions get the same pair.
#
# FLAGS
#   --check       Check the tools and the environment, print the version, build number and commands, build nothing.
#   --no-upload   Archive and export an .ipa into build/export, signed, but do not upload it.
#   --unsigned    Needs no Apple account: archive Release with code signing off and check the result (versions, privacy
#                 manifests, encryption flag, usage strings). This is the check to run before you set up signing.
#
# AFTER IT UPLOADS
#   App Store Connect processes the build for a few minutes, then it appears under the app's TestFlight tab. The first
#   build also needs the export-compliance and test information answered once (see docs/releasing.md).
set -euo pipefail

MODE=release
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-upload) MODE=noupload ;;
    --unsigned) MODE=unsigned ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if [ -n "${RELEASE_ENV_FILE:-}" ]; then
  [ -r "$RELEASE_ENV_FILE" ] || die "cannot read RELEASE_ENV_FILE ($RELEASE_ENV_FILE)"
  # Variables that are already set in the environment win over the file.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      BLOEM_ADMIN_TEAM_ID|ASC_KEY_PATH|ASC_KEY_ID|ASC_ISSUER_ID|MARKETING_VERSION|BUILD_NUMBER|BUILD_DIR)
        eval "current=\${$key:-}"
        [ -n "$current" ] || export "$key=$val" ;;
    esac
  done < "$RELEASE_ENV_FILE"
fi

[ "$(uname -s)" = "Darwin" ] || die "this script needs a Mac with Xcode (xcodebuild)"
command -v xcodebuild >/dev/null || die "xcodebuild not found: install Xcode and run xcode-select"
[ -d BloemAdmin.xcodeproj ] || die "BloemAdmin.xcodeproj is missing: run xcodegen generate"

BUILD_DIR="${BUILD_DIR:-$REPO/build}"
ARCHIVE="$BUILD_DIR/BloemAdmin.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
LOG_DIR="$BUILD_DIR/logs"
SCHEME=BloemAdmin
BUNDLE_APP=com.bloemstudios.admin
BUNDLE_WIDGETS=com.bloemstudios.admin.widgets
BUNDLE_NSE=com.bloemstudios.admin.NotificationService

# ---- version -------------------------------------------------------------------------------------------------------
VERSION="${MARKETING_VERSION:-}"
if [ -z "$VERSION" ]; then
  TAG="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  if [ -n "$TAG" ]; then
    VERSION="${TAG#v}"
  elif [ "$MODE" = unsigned ] || [ "$MODE" = check ]; then
    VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
    note "HEAD has no v<major>.<minor>.<patch> tag; using the project default $VERSION for this $MODE run"
  else
    die "HEAD has no release tag. Tag it (git tag v1.0.0) or set MARKETING_VERSION. This script never tags for you."
  fi
fi
case "$VERSION" in
  [0-9]*.[0-9]*) ;;
  *) die "version '$VERSION' is not <major>.<minor>[.<patch>]" ;;
esac
case "$VERSION" in *[!0-9.]*) die "version '$VERSION' may only hold digits and dots (App Store rule)" ;; esac
BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
case "$BUILD" in ''|*[!0-9.]*) die "build number '$BUILD' may only hold digits and dots" ;; esac

# ---- signing inputs (not needed for --unsigned) -----------------------------------------------------------------------
if [ "$MODE" != unsigned ]; then
  missing=""
  for name in BLOEM_ADMIN_TEAM_ID ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    eval "val=\${$name:-}"
    [ -n "$val" ] || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    if [ "$MODE" = check ]; then
      echo "not set:$missing   (a signed run needs them; see the header of this script)"
    else
      die "not set:$missing (see the header of this script)"
    fi
  else
    case "$BLOEM_ADMIN_TEAM_ID" in
      [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
      *) die "BLOEM_ADMIN_TEAM_ID must be the 10-character Team ID" ;;
    esac
    [ -r "$ASC_KEY_PATH" ] || die "cannot read the App Store Connect key at ASC_KEY_PATH"
    case "$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/" in
      "$REPO"/*) die "ASC_KEY_PATH is inside the checkout: keep the .p8 file outside the repository" ;;
    esac
  fi
  if [ "$MODE" != check ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "the working tree has uncommitted changes: build releases from a clean checkout of the tag"
  fi
fi

AUTH_ARGS=()
if [ "$MODE" != unsigned ] && [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH_ARGS=(-allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "${ASC_KEY_ID:-}"
    -authenticationKeyIssuerID "${ASC_ISSUER_ID:-}")
fi

VERSION_ARGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
if [ "$MODE" = unsigned ]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
else
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="${BLOEM_ADMIN_TEAM_ID:-}")
fi

note "mode: $MODE"
note "version $VERSION, build $BUILD"
note "xcode: $(xcodebuild -version | tr '\n' ' ')"
note "output: $BUILD_DIR"

ARCHIVE_CMD=(xcodebuild archive -project BloemAdmin.xcodeproj -scheme "$SCHEME" -configuration Release
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/DerivedData"
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]}")
if [ "$MODE" = check ]; then
  note "would run: ${ARCHIVE_CMD[*]}"
  note "then: xcodebuild -exportArchive with scripts/ExportOptions.plist (method app-store-connect, destination upload)"
  note "check done, nothing was built"
  exit 0
fi

mkdir -p "$LOG_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

# ---- archive -------------------------------------------------------------------------------------------------------
note "archiving (log: $LOG_DIR/archive.log)"
set +e
"${ARCHIVE_CMD[@]}" > "$LOG_DIR/archive.log" 2>&1
status=$?
set -e
if [ $status -ne 0 ]; then
  grep -E "error:|\*\* ARCHIVE" "$LOG_DIR/archive.log" | sort -u | head -20 >&2 || true
  die "archive failed (see $LOG_DIR/archive.log)"
fi
tail -1 "$LOG_DIR/archive.log"

# ---- check the archive ---------------------------------------------------------------------------------------------
APP="$ARCHIVE/Products/Applications/BloemAdmin.app"
[ -d "$APP" ] || die "no app in the archive"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
check_bundle() {
  dir="$1"; expect_id="$2"; label="$3"
  info="$dir/Info.plist"
  [ "$(plist "$info" CFBundleIdentifier)" = "$expect_id" ] || die "$label: bundle id is not $expect_id"
  [ "$(plist "$info" CFBundleShortVersionString)" = "$VERSION" ] || die "$label: marketing version is not $VERSION"
  [ "$(plist "$info" CFBundleVersion)" = "$BUILD" ] || die "$label: build number is not $BUILD"
  [ -f "$dir/PrivacyInfo.xcprivacy" ] || die "$label: no PrivacyInfo.xcprivacy in the bundle"
  plutil -lint "$dir/PrivacyInfo.xcprivacy" >/dev/null || die "$label: privacy manifest is not valid"
  echo "   ok  $label  $expect_id  $VERSION ($BUILD)"
}
note "checking the archive"
check_bundle "$APP" "$BUNDLE_APP" "app"
check_bundle "$APP/PlugIns/BloemAdminWidgets.appex" "$BUNDLE_WIDGETS" "widgets"
check_bundle "$APP/PlugIns/BloemAdminNotificationService.appex" "$BUNDLE_NSE" "notification service"
[ "$(plist "$APP/Info.plist" ITSAppUsesNonExemptEncryption)" = "false" ] || die "ITSAppUsesNonExemptEncryption is not false"
for key in NSFaceIDUsageDescription NSLocalNetworkUsageDescription; do
  [ -n "$(plist "$APP/Info.plist" "$key")" ] || die "Info.plist lacks $key"
done
[ -f "$APP/Assets.car" ] && echo "   ok  asset catalog (app icon) compiled"
if [ "$MODE" != unsigned ]; then
  ENTS="$BUILD_DIR/app-entitlements.plist"
  codesign -d --entitlements :- "$APP" > "$ENTS" 2>/dev/null || die "cannot read the signed app's entitlements"
  [ "$(plist "$ENTS" aps-environment)" = "production" ] || die "the signed app does not carry aps-environment production"
  echo "   ok  aps-environment production"
  plist "$ENTS" com.apple.security.application-groups | grep -q "group.com.bloemstudios.admin" || die "the signed app lacks the App Group"
  echo "   ok  App Group group.com.bloemstudios.admin"
fi

if [ "$MODE" = unsigned ]; then
  note "unsigned archive is at $ARCHIVE (not uploadable: it has no signature)"
  exit 0
fi

# ---- export (and upload) -----------------------------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
OPTIONS="$BUILD_DIR/ExportOptions.plist"
cp "$REPO/scripts/ExportOptions.plist" "$OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $BLOEM_ADMIN_TEAM_ID" "$OPTIONS"
if [ "$MODE" = noupload ]; then
  /usr/libexec/PlistBuddy -c "Set :destination export" "$OPTIONS"
  note "exporting an .ipa (no upload) (log: $LOG_DIR/export.log)"
else
  note "exporting and uploading to App Store Connect (log: $LOG_DIR/export.log)"
fi
set +e
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTIONS" \
  "${AUTH_ARGS[@]}" > "$LOG_DIR/export.log" 2>&1
status=$?
set -e
if [ $status -ne 0 ]; then
  grep -E "error:|\*\* EXPORT|Error|ERROR" "$LOG_DIR/export.log" | sort -u | head -20 >&2 || true
  die "export failed (see $LOG_DIR/export.log)"
fi
tail -2 "$LOG_DIR/export.log"
if [ "$MODE" = noupload ]; then
  note "done: $(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
else
  note "uploaded version $VERSION build $BUILD. It shows up in App Store Connect > TestFlight once processing finishes."
fi
