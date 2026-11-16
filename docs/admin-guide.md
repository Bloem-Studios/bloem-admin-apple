---
title: Bloem Admin for iOS and iPadOS — Admin Guide
description: How to generate the Xcode project, build, test, sign, distribute, connect and operate the Bloem Admin app for iPhone and iPad, written for someone doing it for the first time.
summary: Toolchain (Xcode 26.6, Swift 6 strict concurrency, XcodeGen 2.46.0), building and testing, the GitHub Actions release gate, signing and bundle identifiers, TestFlight and device installs, HTTPS-only server enrollment, the login / admin-gate / refresh-token model, Keychain and UserDefaults storage, the fail-closed Face ID app lock, idempotent privileged actions, polling and timeouts, diagnostics, security, upgrades and troubleshooting.
tags:
  - admin
  - operator
  - ios
  - ipados
  - build
  - deployment
audience:
  - operator
last_reviewed: 2026-11-13
related:
  - user-guide.md
  - platform-features.md
  - releasing.md
  - design.md
---

# Bloem Admin for iOS and iPadOS — Admin Guide

> [!CAUTION]
> **Offered without support.** Bloem Admin is provided as-is, with no support of any kind. Issues are turned off, questions go unanswered, and pull requests are not accepted: they are closed without review. You are free to fork it under the AGPL v3.

This is the handbook for the person who builds, installs and looks after **Bloem Admin for iOS and
iPadOS**: the companion app that lets a server administrator manage one or more
[Silo](https://siloserver.org) servers from an iPhone or iPad. It assumes you have never built an iOS app before. If a sentence uses a word you
do not know, the [glossary](#glossary) at the end defines it.

If you are the person who *uses* the app day to day — it is already on your phone and you want to
know what each screen does — you want the [User Guide](user-guide.md) instead.

**How this guide is organised.** Part 1 gets a build onto a device and explains the automated
checks that run on every change. Part 2 explains how the app connects to a server and how it keeps its secrets. Part 3
is the reference: every place the app stores something, every timer, every network call. Part 4 is
troubleshooting.

---

## Part 1 — Getting the app onto a device

### 1.1 What Bloem Admin for iOS is

Bloem Admin is a native SwiftUI app for **iPhone and iPad only** — no tvOS, no Mac Catalyst. It is
a *remote control for the admin API* of a Silo server: it stores nothing of its own except the
list of servers you have added and the sign-in tokens for them. Everything on screen is fetched
live from the server.

Four things about it matter before you build it:

- **It is a multi-server app.** Add each server once (address, username, password). A pinned
  **All Servers** entry shows every server's data side by side.
- **It holds real administrator credentials.** It therefore locks itself with Face ID / Touch ID
  (with the device passcode as fallback), refuses to run on a device with no passcode, and keeps
  tokens in the Keychain. Part 2 explains the model.
- **It is HTTPS-only and follows no redirects.** A server address must be a plain `https://`
  origin; any HTTP redirect is refused. Section 2.1 has the exact rules.
- **It works with any Silo server.** A Bloem server is a Silo server with extras, and shares its admin REST API. The
  extras (organizations, platform administration, support access, push notifications) switch on by themselves when the
  server answers as a Bloem server, and are simply absent on a plain Silo server. The server's own name, read from its
  health endpoint, becomes the display name in the app.

### 1.2 What you need before you start

| Requirement | Detail |
|---|---|
| **macOS with Xcode 26.6** | `project.yml` sets `SWIFT_VERSION: "6.0"` and `SWIFT_STRICT_CONCURRENCY: complete`; CI selects `/Applications/Xcode_26.6.app` and builds with warnings treated as errors. An older Xcode may still open the project, but the release gate (1.8) is only proven on 26.6. |
| **XcodeGen 2.46.0** | `brew install xcodegen` for local work. CI installs the pinned 2.46.0 release by SHA-256 and fails if regenerating the project produces any diff, so keep your local version close to 2.46.0. The Xcode project is *generated* from `project.yml`; that file is the source of truth. |
| **A device or simulator on iOS/iPadOS 17.0 or newer** | `IPHONEOS_DEPLOYMENT_TARGET = 17.0`; device families 1 and 2 (iPhone and iPad). CI uses the `iPhone 17` and `iPad Pro 13-inch (M5)` simulators. |
| **An Apple ID in Xcode** | Needed to run on a physical device (free personal team is enough for your own device); an Apple Developer Program membership is needed for TestFlight. |
| **A reachable Silo server over HTTPS** | See 2.1 — plain `http://` is rejected before any network call is made. You need an administrator account on it. |

There is no fastlane configuration and no App Store metadata in this repository. A GitHub Actions
workflow (`.github/workflows/ci.yml`) runs the checks; it builds, tests, analyses and produces an **unsigned**
archive but does not sign or upload anything (1.8). Signing and uploading a build is `scripts/testflight.sh`, run by
hand with your own Apple account ([releasing.md](releasing.md)).

### 1.3 Project layout

```
bloem-admin-apple/
├── project.yml                 # XcodeGen spec: targets, scheme, bundle ids, Info.plist keys
├── BloemAdmin.xcodeproj/       # generated output (committed; CI rejects drift from project.yml)
│   └── xcshareddata/xcschemes/BloemAdmin.xcscheme
├── Config/                     # Signing.xcconfig and its example: the team comes from a git-ignored local file
├── LICENSE, LICENSES/          # AGPL v3 for the code; the font's and the icons' licences
├── THIRD_PARTY_NOTICES.md      # what the repository bundles, and the Bloem name and logo
├── .github/workflows/ci.yml    # the checks (1.8)
├── BloemAdmin/                 # app target sources
│   ├── App/                    # BloemAdminApp, AppLockState, LockScreenView, AdminSessionState
│   ├── Networking/             # APIClient, APIError, AuthAPI, ServerCredentials, KeychainStore,
│   │   │                       # ServerEndpointValidator, ProductionSession, ServerFanOut
│   │   └── API/                # one file of v2 routes per area (the only "/api/ literals)
│   ├── Realtime/               # the events socket: EventsProtocol (frames), EventsSocket (URLSession
│   │                           # WebSocket), LiveSocketConnector (ticket), LiveConnection (one per server:
│   │                           # foreground rules, backoff, watchdog, channels, fallback), LiveHub (scenes,
│   │                           # network path), LiveRefresh (.liveRefresh), LiveSessions (Now playing),
│   │                           # LiveSessionsStatus (the Live / Reconnecting line)
│   ├── Servers/                # server list, add server, admin gate, All Servers
│   ├── Alerts/                 # server alerts: decision logic, background check, notifications, settings
│   ├── Push/                   # push notifications: registrar, runtime, settings, taps and buttons (see platform-features.md)
│   │   └── Core/               # Foundation-only code compiled into the app AND the notification extension
│   ├── Shared/                 # compiled into the app and the widget extension (links, snapshot, intents)
│   ├── Snapshot/               # keeps the widget snapshot current while the app is open
│   ├── <Feature>/              # Dashboard, Streams (Now playing), Activity (Playback history), Jobs (Scheduled tasks), Requests, Users,
│   │                           # Invitations, ServerConfig, Audit, Logs, Tenants (no longer shown),
│   │                           # PlatformOrganizations and SupportAccess (the Platform group, 2.10)
│   ├── Info.plist
│   ├── PrivacyInfo.xcprivacy   # privacy manifest (required-reason API declaration)
│   └── Localizable.xcstrings   # string catalog (English)
├── BloemAdminWidgets/          # widget extension: five widgets, two controls, the Live Activity
├── BloemAdminNotificationService/  # notification service extension: replaces a push's generic text
├── BloemAdminTests/            # unit tests (MockURLProtocol, no network); Resources/api-contract.json
├── scripts/                    # testflight.sh (release), extract-api-contract.py (the contract the tests read),
│                               # generators for icons and colours, screenshot helpers
├── BloemAdminUITests/          # simulator UI tests: smoke tests and a test per group of pages
└── docs/                       # this guide, the user guide, the feature reference, releasing and design notes
```

Five targets are defined in `project.yml`:

| Target | Type | Bundle identifier | Product |
|---|---|---|---|
| `BloemAdmin` | iOS application | `com.bloemstudios.admin` | `BloemAdmin.app` |
| `BloemAdminWidgets` | app extension (WidgetKit) | `com.bloemstudios.admin.widgets` | embedded in `BloemAdmin.app`; compiles `BloemAdmin/Shared` and `HealthProbe.swift` too |
| `BloemAdminNotificationService` | app extension (UserNotifications) | `com.bloemstudios.admin.NotificationService` | embedded in `BloemAdmin.app`; compiles only `BloemAdmin/Push/Core`, `PushDisplayAPI.swift`, `APIPath.swift` and `SecurityClient.swift` (no sign-in, no UI) |
| `BloemAdminTests` | unit-test bundle | `com.bloemstudios.admin.tests` | depends on `BloemAdmin` |
| `BloemAdminUITests` | UI-test bundle | `com.bloemstudios.admin.uitests` | depends on `BloemAdmin` (`TEST_TARGET_NAME`) |

One shared scheme, **BloemAdmin**, builds the app and runs both test targets with code coverage
gathered for the app target (unit tests parallelisable, UI tests not). The app and both extensions take their version
from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (1.0 and 1 for a local build); the three
`Info.plist` files read them as `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`. `scripts/testflight.sh`
overrides both for a release: the version comes from the `vX.Y.Z` tag and the build number is the UTC time
([releasing.md](releasing.md)).

`project.yml` also writes these `Info.plist` keys: the Face ID usage string, a local-network usage
string (`NSLocalNetworkUsageDescription`, because a server may be on the same LAN), an empty
`UILaunchScreen` dictionary (SwiftUI launch screen), and explicit orientation sets — portrait and
both landscapes on iPhone; all four on iPad. It also writes `CFBundleURLTypes` (the `bloemadmin` scheme),
`UIBackgroundModes` (`fetch`), `BGTaskSchedulerPermittedIdentifiers` (`com.bloemstudios.admin.health-check`) and
`UIApplicationShortcutItems` (three quick actions). Both the app and the widget extension carry the App Group
entitlement `group.com.bloemstudios.admin` (`BloemAdmin/BloemAdmin.entitlements`,
`BloemAdminWidgets/BloemAdminWidgets.entitlements`, generated from `project.yml`); signing for a device needs that
App Group enabled on both App IDs. See [Alerts, links, widgets and shortcuts](platform-features.md).

Push works only with a Bloem server, in the official build (the push credentials belong to the official app). A Silo
server cannot push to this app, and a build you make under your own team and bundle identifier does not receive push. Push
adds the `aps-environment` entitlement to the app (`$(APS_ENVIRONMENT)`: `development` in Debug, `production` in
Release, also written to Info.plist as `BloemAPSEnvironment` so the registration can tell the server which APNs the
token belongs to), and gives the notification extension the same App Group and shared keychain group. Push
Notifications must be enabled on the app's App ID, and the extension has its own App ID. The test run
builds with ad hoc signing, so push is covered by unit tests there.
How push works, what it stores and how to turn it off: [Push notifications](platform-features.md#push-notifications).

### 1.4 Generate and build

```sh
xcodegen generate
open BloemAdmin.xcodeproj
```

Then pick a simulator or device in the toolbar and press Run. From the command line:

```sh
xcodebuild build -scheme BloemAdmin -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test  -scheme BloemAdmin -destination 'platform=iOS Simulator,name=iPhone 17'
```

> **Re-run `xcodegen generate` whenever `project.yml` changes or a source file is added or
> removed.** Xcode does not watch `project.yml`; a stale `.xcodeproj` is the most common cause of
> "file not found" build errors after pulling. Commit the regenerated project too — CI regenerates
> it and fails on any difference.

The whole codebase compiles under Swift 6 language mode with complete concurrency checking. A new
file that introduces a data-race warning will fail CI, which builds with
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.

`project.yml` also sets `SWIFT_EMIT_LOC_STRINGS: YES`, which makes the compiler collect
`Text("…")` / `String(localized:)` literals into `Localizable.xcstrings` on build. English is the only
shipped language.

### 1.5 Signing

No team, key or profile is stored in the repository.

- `Config/Signing.xcconfig` is the configuration file of both build configurations. It includes an optional,
  git-ignored `Config/Signing.local.xcconfig`, and is silently skipped when that file does not exist, so a clean clone
  builds. To run on a device or archive from Xcode, copy `Config/Signing.example.xcconfig` to
  `Config/Signing.local.xcconfig` and put your own 10-character Team ID in it. Xcode's default *Automatically manage
  signing* then applies.
- `scripts/testflight.sh` does not read that file. It takes the team from the `BLOEM_ADMIN_TEAM_ID` environment variable and
  passes it on the `xcodebuild` command line, which wins ([releasing.md](releasing.md)).
- The app has an entitlements file (`BloemAdmin/BloemAdmin.entitlements`, generated from `project.yml`): the App Group
  `group.com.bloemstudios.admin`, the shared keychain group `$(AppIdentifierPrefix)com.bloemstudios.admin.shared`, and
  `aps-environment`. The widget extension has the App Group and the keychain group, and the notification extension the
  same two.

CI builds with `CODE_SIGNING_ALLOWED=NO` and runs the tests ad-hoc signed (`CODE_SIGN_IDENTITY=-`),
because an unsigned simulator app cannot use the Keychain; neither needs a certificate.

**Making your own build.** The bundle identifiers (`com.bloemstudios.admin`, `.widgets`, `.NotificationService`), the App
Group and the keychain group belong to the maintainers' team. Under your own team, change them in `project.yml` (all
targets and the entitlements), regenerate, and register the App IDs and the App Group under your team. Your build then has
your own identity: it does not replace the official app, and it does not receive push.

### 1.6 Distribution

There is no in-app updater. CI produces an unsigned `.xcarchive` as evidence only.

**The official build** is distributed through TestFlight by the maintainers, with `scripts/testflight.sh`. It is the only
build that receives push notifications.

**Run on your own device from Xcode.** Connect the device, select it, press Run. With a free
personal team the build expires after seven days and must be re-run; with a paid team it lasts a
year.

**Your own TestFlight build (paid Developer Program).** Run `scripts/testflight.sh` as described in
[releasing.md](releasing.md), or in Xcode choose **Product → Archive**, then in the Organizer **Distribute App →
TestFlight & App Store → Upload**. The bundled privacy manifests (`PrivacyInfo.xcprivacy`, one for the app and one for each
extension) declare the required-reason API use, no tracking, no tracking domains and no collected data types, which is what
App Store review checks.

**Ad-hoc / development IPA.** Archive as above and choose **Distribute App → Custom → Ad Hoc** (or
**Development**) to export an `.ipa` restricted to registered device UDIDs, installable via Apple
Configurator or Xcode's Devices window.

**Upgrading in place.** Installing a new build with the same bundle identifier and team keeps the
app's data. Stored servers live in UserDefaults and credentials in the Keychain (2.5); both survive
an upgrade and are removed when the app is deleted.

### 1.7 Running the tests

`xcodebuild test` (1.4) or **Product → Test** in Xcode runs both test bundles:

- **`BloemAdminTests`** — unit tests: the networking layer (origin validation, redirect refusal,
  v2 collections and conditional writes, credential store and legacy migration), `ServerStore`, the
  admin gate (401 re-login and silent refresh), `APIPathGuardTests` (no `"/api/` literal outside
  `Networking/API/` and `Networking/AuthAPI.swift`, no v1 path except `/api/v1/health`),
  `APIContractTests` (every API and auth function against the generated contract, see 3.2), the
  app-lock state machine including multi-scene behaviour, `ServerFanOut`, and every feature view
  model in success, failure and reload-gating paths. Tests use a `MockURLProtocol` harness — no real
  network.
- **`BloemAdminUITests`** — simulator UI tests. `BloemAdminSmokeTests` has five: a locked launch
  covers administrator content; unavailable device authentication shows the fail-closed message; a
  reset launch shows an empty server list; an `http://` origin is rejected before networking; and
  the lock shield hides a mounted Add Server sheet after foregrounding. The other files drive a group of pages (the
  shell, Dashboard, Now playing, Users, Libraries and so on) against fixtures, with the same launch-argument
  mechanism. Those launch arguments exist **only in Debug builds**: `--ui-testing-reset` (wipe stored servers)
  and `--ui-testing-auth=success|unavailable|success-then-pending` (replace the real Face ID prompt), plus one
  per fixture. Release builds ignore them. Three groups skip themselves unless you ask for them: the screenshot
  tours (`LookTourUITests`, `QualityTourUITests`, which write images and assert nothing) and the live test against a
  real Silo server (`SiloServerLiveUITests`, which needs `SILO_LIVE_URL`, `SILO_LIVE_USER` and `SILO_LIVE_PASSWORD`;
  use a throwaway server, see `scripts/ios-live-silo-test.sh`).

CI runs the full scheme on the iPhone simulator and only `BloemAdminUITests` on the iPad simulator.

`APIPathGuardTests` and `APIContractTests` read the Swift sources through `#filePath`, so they need
the checkout on the machine that runs them (the simulator shares the host Mac's file system).

### 1.8 The CI checks

`.github/workflows/ci.yml` runs on every push to `main` and on manual runs. It does not run on pull requests, because this
repository does not take them. It uses `macos-26` runners with Xcode 26.6, with `permissions: contents: read` and one
concurrent run per branch. Every third-party action is pinned to a commit SHA.

Four jobs:

| Job | What it does | Fails when |
|---|---|---|
| **Generated project is current** | Installs XcodeGen 2.46.0 from the GitHub release (SHA-256 checked), runs `xcodegen generate`, then `git diff --exit-code` and checks for untracked output | The committed `.xcodeproj` (or generated plist) differs from what `project.yml` produces |
| **Unit and UI tests** | `xcodebuild test` on `iPhone 17` (whole scheme) and on `iPad Pro 13-inch (M5)` (`-only-testing:BloemAdminUITests`), both with coverage; uploads `.xcresult` bundles and logs as the `test-results` artifact (14 days) | Any test fails or a destination is missing |
| **Swift 6 builds and analysis** | Debug and Release simulator builds plus `xcodebuild analyze`, all with `SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; uploads `build-analysis-results` | Any warning or analyzer diagnostic |
| **Unsigned Release archive and privacy manifest** | `xcodebuild archive` for `generic/platform=iOS` with signing disabled, then `plutil -lint` and prints the bundled `PrivacyInfo.xcprivacy`; uploads `release-archive-evidence` | The archive fails or the manifest is missing/invalid |

The last three jobs depend on the drift check; the archive job also waits for tests and builds. Nothing in CI signs,
notarises or uploads a build.

**The same checks locally.** Use an installed simulator from `xcrun simctl list devices available`; replace the names below
if your Xcode has others.

```sh
xcodegen generate
git diff --exit-code
test -z "$(git ls-files --others --exclude-standard)"

xcodebuild test -project BloemAdmin.xcodeproj -scheme BloemAdmin \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -enableCodeCoverage YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

xcodebuild test -project BloemAdmin.xcodeproj -scheme BloemAdmin \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest' \
  -only-testing:BloemAdminUITests -enableCodeCoverage YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

xcodebuild build -project BloemAdmin.xcodeproj -scheme BloemAdmin \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO

scripts/testflight.sh --unsigned      # unsigned Release archive, then checks versions, privacy manifests and usage strings
```

Re-run `xcodegen generate` after pulling changes that touch `project.yml` or add or remove source files.

---|---|---|
| **Generated project is current** | Installs XcodeGen 2.46.0 from the GitHub release (SHA-256 checked), runs `xcodegen generate`, then `git diff --exit-code` and checks for untracked output | The committed `.xcodeproj` (or generated plist) differs from what `project.yml` produces |
| **Unit and UI tests** | `xcodebuild test` on `iPhone 17` (whole scheme) and on `iPad Pro 13-inch (M5)` (`-only-testing:BloemAdminUITests`), both with coverage; uploads `.xcresult` bundles and logs as the `test-results` artifact (14 days) | Any test fails or a destination is missing |
| **Swift 6 builds and analysis** | Debug and Release simulator builds plus `xcodebuild analyze`, all with `SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; uploads `build-analysis-results` | Any warning or analyzer diagnostic |
| **Unsigned Release archive and privacy manifest** | `xcodebuild archive` for `generic/platform=iOS` with signing disabled, then `plutil -lint` and prints the bundled `PrivacyInfo.xcprivacy`; uploads `release-archive-evidence` | The archive fails or the manifest is missing/invalid |

The last three jobs depend on the drift check; the archive job also waits for tests and builds.
The README's **Release checks** section lists the equivalent local commands. Nothing in CI signs,
notarises or uploads a build.

---

## Part 2 — Connecting and staying signed in

### 2.1 Server address, HTTPS and the transport

When you add a server (User Guide, 2.2) the app asks for the server's **origin** exactly as a
browser would use it: `https://media.example.com` or `https://192.168.1.20:8090`. Typed without a
scheme (`media.example.com`), the address is taken as `https://`; a scheme that is typed is kept and
checked, so `http://` is still refused.
`ServerEndpointValidator` checks the text before any request is made and rejects anything else:

| Input | Message shown |
|---|---|
| Empty | *Enter the server's HTTPS address.* |
| Not parseable as a URL | *That doesn't look like a valid URL.* |
| `http://` or any scheme other than `https` | Server alerts never arrive | Alerts are off, the server's own switch is off, notifications are off for the app in iOS Settings, Background App Refresh is off or Low Power Mode is on, or the app was force-quit (iOS runs no background task until it is opened again) | Settings, Server alerts: turn alerts and the server on; allow notifications and Background App Refresh in iOS Settings; open the app once. iOS decides how often the check runs, so a delay of hours is normal |
| *The server address must use HTTPS.* |
| No host | *The server address must include a host.* |
| Port outside 1–65535 | *The server address must use a port between 1 and 65535.* |
| `user:pass@` in the address | *The server address cannot include a username or password.* |
| A path, `?query` or `#fragment` | *Enter only the server origin, without a path, query, or fragment.* |

The accepted origin is canonicalised (host lower-cased, an explicit `:443` dropped) and every
request is that origin with an `/api/v2/...` path appended (`/api/v1/health` is the one v1 route). `APIClient` independently refuses to
send to a non-HTTPS base URL, so no code path can downgrade the transport.

> **`http://` does not work — and cannot be made to.** The validator rejects it, the client refuses
> it, and `Info.plist` contains no `NSAppTransportSecurity` dictionary, so App Transport Security is
> fully on as a third layer. Put the server behind HTTPS with a certificate the device trusts. A
> self-signed certificate is refused unless its CA profile is installed and trusted on the device.

Requests go through a dedicated `URLSession` (`ProductionSession`): ephemeral configuration, no
cookies, no cache, a **30 s** per-request timeout and a **60 s** resource timeout. Its delegate
**refuses every HTTP redirect** — a reverse proxy that answers `301`/`302` (for example to add a
trailing slash or to bounce to another host) makes the request fail; point the app at the final
origin instead.

`Info.plist` carries `NSLocalNetworkUsageDescription` (*Bloem Admin connects to media servers added
by an administrator on this network.*). If a server's origin resolves to a LAN address, iOS may show
its **Local Network** permission prompt on first use; denying it makes that server unreachable
until the permission is granted in **Settings → Privacy & Security → Local Network**.

### 2.2 What happens when you add a server

`AdminLogin.enroll` runs four steps in order; a failure at any step leaves nothing saved:

1. A token-less client calls `GET /api/v1/health` (public; the one v1 route the app still uses). The response **must** contain a
   non-blank `server_id`; otherwise enrollment stops with *This server is not compatible with
   Bloem Admin.* A non-blank `server_name` becomes the display name; otherwise the URL's host is
   used.
2. `POST /api/v2/auth/login` with the username and password. On success the server returns an
   **access token**, a **refresh token** and the signed-in user.
3. With the new access token, `GET /api/v2/admin/server/status`. A `404` problem here means the
   server has no v2 route and enrollment stops with an incompatible-server message. A `403` is not the end: the app
   then asks `GET /api/bloem/v2/organizations` with the same token, and an account that is an `admin` of at least one
   organization is saved (the gate opens organization mode for it, 2.3). An account that administers nothing, or a
   server without organizations (`404`), is refused with *This account needs administrator access.* **before** it is
   saved. Any other failure of the lookup is shown as that failure, not as a refusal.
4. A random UUID becomes the server's id; id, URL and display name are saved to UserDefaults and
   the two tokens are written as one Keychain record against that id (2.5).

The password is never stored. Errors you can see at this step:

| Message | Cause |
|---|---|
| One of the validator messages in 2.1 | The address was rejected before any request |
| Server's own message | Login rejected (wrong credentials, disabled account) |
| *This account needs administrator access.* | The account is not a platform administrator and administers no organization (step 3) |
| *This server is not compatible with Bloem Admin.* | `/api/v1/health` answered without a `server_id` — an older or different product |
| *That address isn't a Silo server. Check it and try again.* | The address answered `2xx`, but the response did not decode — usually a web page or a proxy at that URL |
| *Could not reach that server.* | Network failure, refused redirect, ATS/certificate problem, wrong host/port |

### 2.3 The admin gate

Every time you open a server the app probes `GET /api/v2/admin/server/status`:

| Outcome | What the app does |
|---|---|
| 200 | Shows the admin tabs (*Checking access…* spinner while waiting). |
| 401 | Tries a silent refresh (2.4) once; if that fails, shows **Sign In Required**. |
| 403 | Asks `GET /api/bloem/v2/organizations` with the same account token. At least one membership whose `membership_role` is `admin` admits the account into **organization mode** (2.8), straight in for one and a choice for several. No such membership, or a `403` or `404` on that lookup, shows **No Admin Access** — *This account doesn't have admin access on <server>.* — with **Retry**, which runs the check again (the role may have been restored). A `401` there goes to re-login; an answer the app cannot decode is **Incompatible Server Response**; any other failure is **Connection Lost**; both offer **Retry** (as on Android). |
| Response that does not decode | Shows **Incompatible Server Response** with *The server returned an incompatible response.* and a **Retry** button. |
| Any other failure | Shows **Connection Lost** with the server's message, *No internet connection.*, *Request timed out.*, or the fallback *Could not verify administrator access.*, plus **Retry**. |

The Tenants tab is not part of the gate any more: it is no longer shown on any server (see 3.2); platform administrators
get Platform › Organizations instead (2.10). A platform administrator (a 200 on the probe) is admitted exactly as before
and the organization lookup is not made.

### 2.4 Tokens, expiry and silent refresh

Every admin request carries `Authorization: Bearer <access token>`. When a request on a
single-server screen returns **401** for the administrator credential:

1. The app calls `POST /api/v2/auth/refresh` with the stored refresh token (token-less client).
   Concurrent 401s on several tabs share one in-flight refresh per server (single-flight).
2. On success the server returns a *new* access token **and** a *new* refresh token; both are
   stored together and the shared client picks them up before the next request. A list that was
   paginated when the token expired resumes from where it was.
3. On failure — no refresh token stored, network failure, or the server answering 401 with
   `session_revoked` / `invalid_token` — the **Sign In Required** form is shown: *Your session on
   <server> has expired. Sign in again to continue.*

Notes for server-side debugging:

- The refresh token is **single-use** and rotates on every exchange.
- A 401 or 403 is only acted on if it belongs to the **current** credential generation. A late
  response from a request that started before a re-login is ignored, so a
  stale request can never sign out a fresh session.
- In **All Servers**, silent refresh is not attempted. A section whose token expired shows an
  inline sign-in (*Sign in again to <server> to include it in All Servers.*).

### 2.5 Where the app stores things

| What | Where | Protection |
|---|---|---|
| Server list — `id` (UUID), `baseURL`, `displayName` per server | `UserDefaults.standard`, key `bloem.admin.servers`, JSON-encoded array | Standard app-sandbox data; contains no secrets; declared in the privacy manifest |
| Access token + refresh token per server | **One** Keychain generic-password item, service `com.bloemstudios.admin.credentials.v1`, account = server id, value = JSON `{version: 1, accessToken, refreshToken}` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Passwords | Not stored | — |
| Server alert switches (master, per server, details on the lock screen) and per-server check state | `UserDefaults.standard`, keys `bloem.admin.alerts.*` | Standard app-sandbox data; no secrets; readable after first unlock, which is when a background check runs |
| Widget snapshot — per server: id, name, origin, whether it answered and when, active streams, requests waiting and when | `admin-snapshot.json` in the App Group container `group.com.bloemstudios.admin` | File protection until first unlock; **never a token**, user name, email or title |

`WhenUnlockedThisDeviceOnly` means the items are readable only while the device is unlocked (the
app is itself locked whenever the device is), are never synced to iCloud Keychain, and are not
restored onto a *different* device from a backup; a restore onto the same device keeps them. Tokens
are never logged and never placed in UserDefaults.

**Legacy records.** Builds before the combined record kept two separate Keychain items per server
(services `com.bloemstudios.admin.token` and `com.bloemstudios.admin.refreshtoken`). On the first
read of a server that still has them, the app writes the combined record, reads it back to verify
it, and only then deletes both legacy items; a deletion that fails part-way is retried on the next
read. All reads, migrations, saves and deletes for one server are serialised behind a per-server
lock, so two iPad windows cannot interleave Keychain operations for the same server.

**Failure handling.** If the server list cannot be decoded at launch, the app starts with an empty
list and shows **Saved Data Could Not Be Updated** with the underlying error. Adding a server that
cannot be persisted rolls the Keychain write back so no orphaned credential remains.

**Sign Out** on a server deletes the Keychain record but keeps the list entry; **Remove Server**
deletes the entry and the record. Deleting the app removes everything.

### 2.6 No impersonation

The app cannot act as another user. The security baseline removed impersonation, so there is no
Impersonate action, no banner and no call to an impersonation route. **Audit** still displays the
attribution (*as <admin id> → <user id>*) of requests that other clients made while impersonating.

### 2.7 The app lock

The whole interface sits behind a local-authentication gate that **fails closed**:

- The app starts **locked**; the lock screen (the app's mark, *Bloem Admin is locked*, *Unlock with
  Face ID, Touch ID or your passcode.* and an **Unlock** button) appears and the system prompt is
  triggered automatically with the reason *Unlock Bloem Admin*. Tapping **Unlock** re-triggers it.
- Policy is `LAPolicy.deviceOwnerAuthentication`: Face ID or Touch ID first, with the **device
  passcode** as the built-in fallback. The Face ID usage string in `Info.plist` is *Bloem Admin uses
  Face ID to keep admin access to your media servers locked when the app isn't in use.*
- If the device has **no passcode and no biometrics** (`canEvaluatePolicy` is false) the app
  **stays locked**. The lock screen says *Turn on a passcode, Face ID or Touch ID in Settings to use
  Bloem Admin.* and the button reads **Try again**. There is no bypass.
- The app **re-locks the moment a scene becomes inactive or goes to the background** — including
  pulling down Control Centre, opening the app switcher, or the system authentication sheet itself
  appearing — and prompts again when the scene is active. A dedicated shield `UIWindow` is placed
  above every mounted sheet, alert and navigation stack, so the app-switcher snapshot shows the
  lock screen rather than server data, and the underlying UI is hidden from VoiceOver while locked.
  In-progress UI state (a half-filled form) survives the lock.
- Locking is **per scene**: on iPad each window has its own lock state; concurrent prompts from two
  windows are coalesced into one, and a window that is closed while a prompt is pending cannot
  unlock a surviving one.

There is no in-app setting to turn the lock off.

### 2.8 Contexts, the organization pass and organization mode

A **context** is a place an account may administer. The web admin and this app use the same two kinds and the
same key: `platform`, or `organization:<organization id>`.

**How the app finds the contexts.** `APIClient.listAdminContexts(platformAdmin:)` lists the account's own
memberships with `GET /api/bloem/v2/organizations` (only active memberships of active organizations, each with
`membership_role`, `policy_revision` and `security_revision`); `discoverAdminContexts()` first runs the gate probe
(2.3: 200 means platform administrator, 403 means not). A platform administrator gets *Platform* and one
organization context per membership; anyone else gets a context only for memberships whose role is `admin`. A
server without organizations answers 404 and has none. The context dropdown another part of the app builds lists
each server's organizations from `listAdminContexts`; Platform comes first.

**The pass.** The account's login token is never accepted on `/api/bloem/v2/admin/**`. The app exchanges it for a
**context pass** with `POST /api/bloem/v2/admin/session`, body `{"scope":"organization","organization_id":"…"}`.
The answer holds `access_token`, `expires_at` and the context (`policy_revision`, `security_revision`, authority).

- The pass lives **at most 15 minutes** and is bound to the login session it came from. It is the bearer for every
  `/api/bloem/v2/admin/organization/**` request. The server reads the organization from the pass, never from a URL
  or body, so a route cannot be pointed at another organization; an ID that belongs to another organization (a
  person, a group, an invitation) answers 404.
- The pass is **held in memory only** — in `OrganizationSession` and the `APIClient` it makes for the pass — and is
  never written to disk, a log or saved state. `AdminSessionResponse`, `InvitationHandoff`, `PeopleSelection`,
  `BulkJobRequest` and `ClaimLink` print `<redacted>`. Leaving the organization closes the session and drops it.
- The app refuses a pass that is not for exactly the organization it asked for, or whose scope is not `organization`.
- Each `OrganizationSession` uses one URLSession for every pass it receives; `close()` drops the pass, and a renewal
  still in flight when it closes is not installed.
- Answers are read strictly: a field that is missing or `null` takes its default, but a malformed field or one bad
  row fails the whole answer, so a broken reply reads as *incompatible*, never as "nobody" or "no access".
- Nothing platform-level is reachable from an organization: its pages come from one list (`OrganizationPage`),
  its calls go through the pass client, and no `/admin/platform/**` or `/api/v2/admin/**` route is called with it.

**Renewal, and why a write is never repeated.** The server re-checks the login session, the account, the
membership, the organization's status and revisions, and the role on **every** request.

| Case | What the app does |
|---|---|
| A **read** answers 401, or the pass has under a minute left | Mints a new pass once (parallel reads share the one mint) and repeats that read once; a second 401 is shown |
| A **write** is about to be sent and the pass has under a minute left | Mints a new pass first, then sends the write |
| A **write** answers 401 or 409 `authorization_state_changed` | Mints a new pass, **does not send the write again**, reloads the page and tells the administrator *Someone else changed this just now…* or *This organization changed…*. They look and ask again |
| A write succeeds on access groups | Renews the pass so the next group write quotes the revision the server holds now |
| The mint answers 401 | The login itself expired: the gate's re-login form |
| The mint, or any route, answers 403 or 404 | Access is gone: see below |

Why no replay: an invitation's claim token is shown once, and a bulk job, a group, or a give-back is not safe to
repeat after an uncertain answer. `OrganizationSession.write` never repeats its block; the tests send each kind of
write through a stale pass and count requests.

**Which revision a write quotes.**

| Write | Revision |
|---|---|
| Suspend or reactivate a membership; move a profile | the person's `security_revision` (from the person the page shows) |
| Pause, restore or give back a library | that entitlement's `security_revision` |
| Create, save or delete an access group; create, resend or revoke an invitation | the organization's `policy_revision` (from the pass) |
| A bulk change | none: a signed, short-lived selection token that names who was selected |
| Issue a reset link; sign out everywhere | the person's `security_revision` (a reset link checks it without raising it; signing out everywhere raises it) |
| Rename a profile, clear its PIN, remove it | that **profile's** own `revision` (`profiles[].revision`), never the person's |
| Add a profile; sign out of one session or one device; stop or message a stream | none (a message carries Silo's `command_id` and `sequence`) |

`DELETE` routes read their revision from a JSON body (`APIClient.delete(_:body:)`); the people writes use `PATCH`
(`APIClient.patch`).

**Losing access.** The app distinguishes *why*, from the server's `error` code:

| Server answer | Message | Meaning |
|---|---|---|
| 403 `organization_suspended` | *This organization is suspended. Contact the server owner.* | The organization is suspended |
| any other 403 (`insufficient_organization_authority`, `insufficient_platform_authority`) | *You no longer administer this organization.* | The role is no longer `admin`, the membership ended, or platform authority was lost |
| 404 on the mint | *You don't have access to this organization.* | The server does not show this organization to the account at all |
| 404 on a renewal that names a support access | *Support access to this organization has ended. To keep helping, open it again with a new reason.* | The break-glass access was closed or its four hours are over (2.9) |

`OrganizationSession.denial` keeps the first reason, so a suspended organization is not later reported as lost
authority. The host then shows the reason and **Choose another organization**, and the choice leaves out an
organization the server turned away. A platform administrator opens an organization context through an active
membership; without one, only the server Owner can, through break-glass support access with a reason (2.9), and
everyone else gets the same 404 as before.

**Entry point for the integrator.**
`OrganizationAdminRootView(session:accountSession:title:onChooseContext:onDenied:usesEnclosingNavigationStack:)` opens
the pass and shows the pages. `OrganizationAdmissionView` is what the gate shows for an organization-only administrator.
Build the session with `OrganizationSession.make(server:store:sessionState:organizationID:)`.

- **Page search.** The organization menu has the app's page search (`PageSearchSheet`). `AdminDestination.organization(_:)` turns each
  offered `OrganizationPage` into a destination of the Organization group (ids `organization.<page>`, the web's
  words as keywords, Android's descriptions), so search never lists a platform page; picking one pushes it onto the
  menu's stack (the sidebar selects it on iPad) once the search sheet has closed. `OrganizationPageSearchTests` and
  `OrganizationUITests` (`testSearch…`) cover it.
- **Navigation.** Pass `usesEnclosingNavigationStack: true` whenever the view sits inside a NavigationStack (the
  gate does, because the server list pushes it). The menu is then a plain list that pushes each page onto that stack.
  With `false` (the default, for a window root) the view brings its own NavigationStack on iPhone and a
  NavigationSplitView on iPad. A NavigationStack nested in a pushed page is not supported by SwiftUI: on an iPhone,
  tapping a page in it went straight back to the server list.
- **Links name views, not values.** The server list pushes the gate with a destination-view `NavigationLink`, and a
  NavigationStack keeps views pushed that way above anything pushed by value, so a value link inside the
  organization put its page *under* the menu. Every link inside the organization therefore names its destination
  view (`NavigationLink { … } label: { … }`) or uses `navigationDestination(item:)`; none uses
  `NavigationLink(value:)`.
- **The gate keeps an admitted organization.** The organization's pages cover the gate, and `AdminGateView` checks
  access each time it appears. `AdminGateViewModel.shouldCheckAccessOnAppear` is false once the state is
  `.organizationOnly`, so closing a page does not throw the open organization away. Leaving to the server list and
  opening the server again builds a new gate, which checks.

`OrganizationUITests.testUnderTheServerListPagesPushInsideTheOrganizationAndTheGateStaysPut` mounts the organization
this way (`--ui-testing-organization=nested`), under a stand-in for the gate that counts its checks.

**Tests.** `OrganizationSessionTests` (the pass, renewal, no replayed writes, denial reasons),
`OrganizationDecodingTests` (fixtures shaped exactly like the server's handlers, requests, vocabulary),
`OrganizationPageViewModelTests` and `OrganizationPeopleViewModelTests` (every page's view model, bulk), and
`AdminGateOrganizationTests` (platform administrator, organization-only administrator, neither). The UI tests
(`OrganizationUITests`) start the app with `--ui-testing-organization` (or `--ui-testing-organization=suspended`);
a DEBUG-only stub server inside the app process answers the host `fixture.example.test`, so no request leaves the
device. The narrow-phone bulk bar is checked at the largest accessibility text size.

**What the server does not offer organization administrators** (so the app shows none of it): per-person activity,
setting a PIN, parental fields, policy previews and "change plan" jobs, storage sources and request integrations. On a
server without organization support (2.9) there is also no reset link, no sign-out, no profile editing and no streams.

### 2.9 Organization support

The server's organization support routes (feature token
`organization_support_v1`) let an organization administrator help their own people: a reset link, signing a member
out, profile edits and the organization's own streams. They all sit under `/api/bloem/v2/admin/organization` and take
the organization pass (2.8). The app mirrors the server's rules and shows its refusals; it never decides authority
itself.

**Capabilities gate everything.** After the pass opens, `OrganizationSession.loadSupportCapabilities()` reads
`GET …/support-capabilities` once (`SupportCapabilities`: `password_reset.email|link`, `sessions`, `devices`,
`profiles.add|rename|clear_pin|remove`, `streams.list|stop|message`). Every action, section and the **Streams** page
is shown only when its flag is true. A server that predates the routes answers 404, which counts as *nothing new*
(`SupportCapabilities.none`); any other failure leaves the answer unknown (nothing shown) and the next page asks
again. A capability is never inferred from a failed call.

**Who may act on whom** is the server's table: an administrator helps ordinary members; the
organization owner also helps the other administrators; only a platform administrator helps the owner; a platform
account keeps the server Owner rule; nobody acts on themselves. The app hides the actions on your own page (it knows
that much from the pass's membership) and otherwise sends the request. A refusal is `409 target_protected` with a
`reason` (`self`, `platform_account`, `organization_owner`, `organization_admin`), never a 403, so it never closes
the organization. `APIError` now carries the body's `reason` and `capability`, and
`OrganizationVocabulary.supportRefusal` words every support code: `target_protected`, `membership_not_active`,
`account_shared`, `password_login_disabled`, `account_disabled`, `email_unavailable`, `capability_not_configured`
(email or link), `name_conflict`, `primary_profile_protected`, `profile_limit_reached`, `stale_sequence`,
`realtime_unavailable`, `idempotency_conflict`, `rate_limited` (with the wait from `Retry-After`) and
`dependency_unavailable`. The People page's existing suspend and group-move writes and the bulk jobs follow the same
table now, so their refusals read the same way (a bulk job reports `target_protected`).

**The person page** (`OrganizationPersonSupport.swift`, `OrganizationPersonSupportViews.swift`):

| Action | Route | Notes |
|---|---|---|
| Email a reset link / create one to hand over | `POST people/{account_id}/password-reset` `{expected_revision, delivery}` | 24 h by email, 4 h for a link. The link (`reset_url`) is a bearer credential: held only in `OrganizationPersonViewModel.resetLink` until **Done**, copied with the local-only pasteboard writer (ten minutes), never printed (`SupportReset`, `ResetLinkHandoff` redact it) |
| List sign-ins and devices | `GET people/{id}/sessions`, `GET people/{id}/devices` | No address and no impersonation sessions arrive. Listing writes no audit and spends no budget, so the page loads them on open |
| Sign out everywhere | `DELETE people/{id}/sessions` `{expected_revision}` | Raises the person's `security_revision`; the page takes the person from the answer, so the next write quotes the new revision |
| Sign out of one session / one device | `DELETE people/{id}/sessions/{session_id}`, `DELETE people/{id}/devices/{device_id}` | 204, no revision; a device sign-out forgets its registration and does not stop a stream |
| Add a profile | `POST people/{id}/profiles` `{name, group_id?}` | No PIN, no parental fields |
| Rename / clear PIN / remove | `PATCH …/profiles/{profile_id}/details`, `DELETE …/pin`, `DELETE …/profiles/{profile_id}` | Quote the profile's `revision`; the main profile is never offered for removal |

Each write is sent once through `OrganizationSession.write`. A stale revision (`409 authorization_state_changed`)
renews the pass, reloads the person and says so; it is never replayed. Any other failure also reloads the person, so
the page shows what the server holds.

**Streams** (`OrganizationStreams.swift`): `GET streams?limit=100&cursor=…`, every page up to five, read again when the organization live socket's
`org.streams` channel says a stream changed (no timer while it is up), and polled every ten seconds while the page is open on a
server without the socket or whose socket does not serve that channel. Each row is drawn by the platform's
`StreamRowView` with its default `showClientIP` (off); `SupportStream.playbackRow` fills an `AdminSession` from the
support fields only, so addresses, nodes, routing, bitrates and codecs are nil and have nothing to show
(`StreamClientIPGuardTests`, `OrganizationBoundaryTests` and `OrganizationSupportDecodingTests` check it). **Stop** is
`POST streams/{session_id}/stop` (Silo's terminate: authority revoked first, then the player told; safe to repeat).
**Message** is `POST streams/{session_id}/message` with a `command_id` and `sequence` from a
`PlaybackCommandSequencer`; a `409 stale_sequence` moves the sequencer above `X-Silo-Latest-Sequence` for the next try.
The server's `can_stop` and `can_message` decide which rows offer each.

**Break-glass support access (the server Owner).** `POST /api/bloem/v2/admin/session` takes an optional
`support` object. `OrganizationSession.openSupport(reason:)` sends `{"reason": …}` once (10 to 500 characters, one
line); the answer's context has `access_basis: support`, `authority: platform_admin`, no membership, a
`support_access_id` and `support_expires_at` (four hours at most). Every renewal sends `{"access_id": …}` instead,
never the reason again; a renewal answered 404 means the access is over (`.supportEnded`). `endSupportAccess()` sends
`DELETE …/support-access` (204, or 404 if it had already ended) and closes the session.

- **Who sees it.** `SupportAccessEligibility.check` shows the **Support Access** page (`AdminDestination.supportAccess`,
  in the Users group of one server's menu) only when `GET /api/bloem/v2/capabilities` lists `organization_support_v1`
  and the signed-in account is the server Owner (`GET /api/v2/account/me`, then that user's `is_owner`). Anyone else
  would get the server's 404.
- **The list** (`SupportAccess/`) mints a **platform pass** (`{"scope":"platform"}`, memory only, renewed once on a
  401) and reads `GET /api/bloem/v2/admin/platform/organizations?status=active`, leaving out organizations the Owner
  belongs to. This code lives outside `Organization/`, which still reaches nothing platform-level.
- **Opening** asks for the reason, then pushes the organization (`usesEnclosingNavigationStack: true`) onto the page's
  own NavigationStack. `SupportAccessListModel` remembers the access for the rest of the run, so reopening within its
  four hours names the access instead of asking again.
- **While it is open**, `OrganizationSupportBanner` sits above every organization page with the time left, and on the
  organization's menu offers **End access**. The organization's Activity shows the opening, its reason and every change
  as *Platform support* (`actor_authority: platform_support`, no account id).

**Tests.** `OrganizationSupportSessionTests` (support mint and renewal, ending, capabilities, refusal words),
`OrganizationSupportDecodingTests` (every support answer, older shapes, redaction), `OrganizationPersonSupportTests`
(each action's request and result), `OrganizationStreamsViewModelTests` (paging, polling, stop, message identity),
`SupportAccessTests` (eligibility, the platform list, opening and reopening), `OrganizationSupportStringsTests`, the
contract cases in `APIContractTests`, and `OrganizationSupportUITests` (`--ui-testing-organization=support` and
`=support-access`).

### 2.10 Platform organizations

**Platform › Organizations** is the first group of a Bloem server's menu (one server at a time, not All servers). Every
platform administrator sees it, not only the server Owner. It is offered when the server answers the public
`GET /api/bloem/v2/capabilities` (`PlatformOrganizationsEligibility`); a plain Silo server, or one that cannot be asked,
leaves it out. Support Access (2.9) stays in the same group for the Owner. All of this code lives in
`BloemAdmin/PlatformOrganizations/` and `BloemAdmin/SupportAccess/`, outside `Organization/`
(`OrganizationBoundaryTests` forbid `/admin/platform` paths there); the routes are in
`Networking/API/PlatformOrganizationsAPI.swift`.

**The platform pass.** `PlatformPass` mints `POST /api/bloem/v2/admin/session` `{"scope":"platform"}` with the account
token, holds the pass in memory only, and refuses an answer whose context is not `platform`. A read that meets `401
authorization_state_stale` or `401 tenant_session_required` renews the pass once and is asked again. A write is sent
once: a stale pass is renewed and `PlatformStateChanged` tells the model to reload and ask the person to look again, and
`409 authorization_state_changed` is reported the same way (`wasConflict`). `SupportAccessListModel` uses the same class.

**The list.** `GET /api/bloem/v2/admin/platform/organizations?query&status&cursor&limit`. `status` is `active`,
`suspended` or `initializing` (anything else is a `422`); the filter's "Any" sends none. Fifty rows are asked for, a
search starts again from the first page (a late answer to an earlier search is dropped), and **Show more** follows
`next_cursor`. Each row carries `membership_count`, `profile_count` and `library_count`.

**One organization.** `GET .../organizations/{id}` (counts, `owner_account_id`, `policy_revision`) and
`GET .../organizations/{id}/memberships?cursor&limit` (`username`, `email`, `legacy_role`, `status`, a hundred at a
time). The owner is shown by name, never as an account number: from the members already loaded, else from
`GET /api/v2/admin/users/{id}` with the account token, else *Not available*. A member is **Owner** when the account is
`owner_account_id`, else **Administrator** for `legacy_role: admin`, else **Member**. **Open as administrator** is shown
only when `router.organizations` (the organizations `discoverAdminContexts` found this account administers) lists the
organization under this server, and it calls the same selection the context menu does.

**Suspend and reactivate.** `POST .../suspend` and `POST .../reactivate` with `{"expected_revision": <policy_revision>}`,
the revision the person saw. They go through `PlatformPass.write`, so they are never sent twice; on a conflict or a stale
pass the page reloads and says so. The confirmation words are `PlatformOrganizationText.suspendConsequence` (how many
active members lose access, and that nothing is deleted) and `reactivateConsequence`.

**Plan.** `GET .../organizations/{id}/entitlement` (`template_key`, `template_revision`, `tenant_limits`,
`managed_default_group.policy`, `last_reconciled_at`) and `GET /api/bloem/v2/admin/platform/entitlement-templates?status=enabled`
for the picker. **Preview changes** is `POST .../entitlement/dry-run` `{template_key, template_revision}`; it changes
nothing and returns a `confirmation_token` valid for ten minutes plus the policy the plan gives. Because the server's own
`changes` list holds only the revision, the confirmation compares the organization's current default settings with the
previewed policy setting by setting (`PlanChangeSummary`, in the web's words from `policyVocabulary.ts`). **Apply** is
`POST .../entitlement/apply` `{template_key, template_revision, dry_run_token, idempotency_key}`, sent once through
`PlatformPass.write`; the idempotency key is made when the preview is, so asking again after a lost answer is the same
attempt. `409 confirmation_stale` and a renewed pass both ask for a new preview.

**All servers.** `AggregatePlatformOrganizationsModel` keeps one section per saved server (`loading`, `unavailable`,
`loaded`, `failed`), each with its own `PlatformPass`: a server with no saved sign-in is not asked and offers sign-in; a
`404` on `GET /api/bloem/v2/capabilities` marks a server that is not a Bloem server as unavailable without calling a
platform route; a failure on one server never changes another's section. Search and status are shared and sent to each
server. A server with another page of organizations offers **Show all on (server)**, which selects that server and its
Organizations page. `AggregatePlatformOrganizationsModelTests` cover each of these. The All servers menu therefore
has the Platform group (Organizations only) before Overview, and a sideways swipe from Now Playing goes to it.

**Organization mode Overview.** The owner's name is read from the organization's own `GET .../organization/people/{owner_account_id}`
(an organization-only administrator cannot read the platform account list). If that fails the Overview says *Not
available*; it never shows `Account <n>`.

**Tests.** `PlatformPassTests` (mint, renewal, no replay of a write), `PlatformOrganizationsAPITests` and the
`APIContractTests` cases (every route, query and body against the generated contract), `PlatformOrganizationsModelTests`
(search, filter, paging, failures, who sees the page), `PlatformOrganizationDetailModelTests` (owner by name, members,
suspend, reactivate, a lost race, a stale pass), `PlatformPlanModelTests` (plan, preview, apply, stale previews),
`PlatformPresentationTests` (the words), `AdminDestinationTests` (the Platform group), and `PlatformOrganizationsUITests`
(`--ui-testing-platform-organizations`, an in-process stub server in `PlatformOrganizationsUITestHost.swift`).

---

### Look, fonts and licences

- **Fonts.** Plus Jakarta Sans (SIL OFL 1.1) is bundled as one variable font, `BloemAdmin/Resources/Fonts/PlusJakartaSans-Variable.ttf`,
  registered in `project.yml` under `UIAppFonts` (and mirrored in the checked-in `Info.plist`). Its licence is
  `LICENSES/PlusJakartaSans-OFL.txt`; ship it with any binary distribution.
- **Icons.** Lucide (ISC, `LICENSES/Lucide-ISC.txt`) as SVG template images `lucide.<name>` in
  `BloemAdmin/Resources/Icons.xcassets`, listed in `BloemAdmin/Theme/BloemIcon.swift` and written by
  `scripts/lucide-icons.py`. No SF Symbols.
- **Type scale.** Text uses `.bloemText(.bodyMedium)` and the other named styles in `Shared/BloemFont.swift`
  (the scale in [design.md](design.md)), never `.font(...)`.
- **Colours.** `Assets.xcassets` holds the palette, written by `python3 -I scripts/theme-colors.py` and checked
  by `ThemeContrastTests` in all four appearances. Change a colour in the script, run it, then run the tests.
- **Appearance.** Settings has System, Light and Dark, stored in `UserDefaults` (`appearancePreference`).
  The app's accent is applied once at the root; do not set `.tint` or system colour names on individual views.
- **Adding files** such as a colour set or font needs `xcodegen generate`; the test script runs it, and
  `COPY_PBXPROJ=1` copies the regenerated project back.

## Part 3 — Reference

### 3.1 Network client

| Property | Value |
|---|---|
| Transport | `ProductionSession.make()`: ephemeral `URLSession`, no cookies or cache, 30 s request / 60 s resource timeout, redirects refused. The events socket gets a session of its own per connection (`ProductionSession.socketConfiguration()`: same rules, 1 h resource limit), closed with the socket |
| Concurrency | `APIClient` is an `actor`; one instance per server per view hierarchy, resolving the current administrator credential from `AdminSessionState` on every request |
| Body format | JSON, ISO-8601 dates, snake_case keys mapped via `CodingKeys` |
| Auth header | `Authorization: Bearer <token>` when a credential is available |
| Query strings | Empty values dropped; only non-empty filters are sent |
| Error handling | Non-2xx → `APIError(statusCode, code, message, requestIdentity)`; message is the server's `message` (or `error.message`) field if parseable, otherwise *Request failed*. `URLError` maps to *No internet connection.* / *Request timed out.*; an undecodable body maps to *The server returned an incompatible response.* |
| All Servers fan-out | Each server's request runs concurrently with its own **10 s** timeout (`ServerFanOut.fanOut(timeout:)`); a server with no stored token is reported as *not signed in* without a request |

Errors are surfaced two ways in every feature: `errorMessage` (a list failed to load) drives the
full-screen failure page (`loadFailure`, a `ServerSectionFailure`: *Can't reach the server*, *Signed out*, *No access*, *Server error <status>*, *Unexpected response*, with **Try again**; `errorMessage` is its text); `actionErrorMessage` (an action failed) is shown in red under
the actions, so a failed action never makes a working list look disconnected.

**Lists and writes on v2.** List routes answer `{"items":[...],"page":{"has_more","next_cursor"}}`;
`page` may be absent, which means everything came back in one response. `readAllPages` follows
`next_cursor` and stops on a repeated cursor or after 50 pages. Settings, schedule and user writes
send `If-Match` with the `ETag` read earlier and are never replayed after a 401 or a 412; a `412`
shows a conflict and reloads. Errors arrive as problem+json (`type`, `title`, `status`, `detail`) or
Bloem-native `{"error","message","code"?}`; a `410 client_upgrade_required` shows *This server needs
a newer version of Bloem Admin.*

Stream commands carry a command id and a sequence taken from wall-clock milliseconds, strictly increasing per session. On every
detail screen a `PrivilegedMutationGate` disables all action buttons while one action is in flight,
so a double tap cannot queue a second request.

### 3.2 Every endpoint the app calls

| Screen / action | Method and path |
|---|---|
| Add server (health identity) | `GET /api/v1/health` (the one v1 route) |
| Add server, re-login | `POST /api/v2/auth/login` |
| Add server (admin check); admin gate; Server tab status | `GET /api/v2/admin/server/status` (after a `403`, add server and the gate also read `GET /api/bloem/v2/organizations`) |
| Silent refresh | `POST /api/v2/auth/refresh` |
| Playback history | `GET /api/v2/admin/playback-history` (`limit`, `cursor`, `user_id`, `profile_id`, `completed=true|false`); the pickers read `GET /api/v2/admin/users` and `GET /api/v2/admin/users/{id}/profiles` |
| Logs | `GET /api/v2/admin/logs/app` (`limit`, `cursor`, `level` (comma-separated), `q`, `component`, `request_id`, `playback_session_id`); the session summary reads it and `logs/audit` once each with `playback_session_id` and `limit=200` and counts the rows |
| Audit | `GET /api/v2/admin/logs/audit` (`limit`, `cursor`, `user_id`; `playback_session_id` for the session summary) |
| Dashboard (every poll) | `GET /api/v2/admin/stats` (`?refresh=true` on pull-to-refresh); `GET /api/v2/admin/system/resources`; `GET /api/v2/admin/server/status`; `GET /api/v2/admin/nodes`; `GET /api/v2/admin/stats/playback-activity?hours=24` and `GET /api/v2/admin/stats/timeseries?hours=1`; `GET /api/v2/admin/playback-history?limit=5` |
| Dashboard (slow tier, at most every 5 min, and on pull-to-refresh) | `GET /api/v2/admin/system/build`; `GET /api/v2/admin/stats/timeseries?hours=24`; `GET /api/v2/admin/stats/top-activity?days=7&limit=5`; `GET /api/v2/libraries`; `GET /api/v2/admin/users?limit=200` |
| Dashboard (chart window chosen) | `GET /api/v2/admin/stats/timeseries?hours=168|720` and `GET /api/v2/admin/stats/playback-activity?hours=1|168|720`, read once when chosen, then with the slow tier (the 1h playback window on every load); `refresh=true` only on pull-to-refresh |
| Now playing, Dashboard's Now playing | `POST /api/v2/events/ws-ticket`; `GET /api/v2/events/ws` (WebSocket, `silo.events.v2`, sessions channel, shared with the other screens; see 3.3); `GET /api/v2/admin/sessions`; `POST /api/v2/admin/sessions/{id}/pause|resume|stop|terminate`; `POST /api/v2/admin/sessions/{id}/message` |
| Playback history | `GET /api/v2/admin/playback-history?limit=50[&cursor=][&user_id=]` |
| Scheduled tasks | `GET /api/v2/admin/tasks` (no paging; `last_execution`, `next_run_at`, `progress` feed the row); `GET /api/v2/admin/tasks/{key}` (the backup task's next run); `POST /api/v2/admin/tasks/{key}/run|cancel`; `GET /api/v2/admin/tasks/{key}/history` (cursor paged, `limit` 1 to 200, 20 used); `GET|PUT /api/v2/admin/tasks/{key}/triggers` (`If-Match`; interval, startup, daily, weekly, `max_runtime_ms`) |
| Libraries | `GET /api/v2/libraries` (not paged); `GET /api/v2/scan/capabilities`; `POST /api/v2/scan` and `POST /api/v2/scan/cancel` (body `library_id`); `GET /api/v2/admin/autoscan/scans?status=accepted|running&limit=50` and `GET /api/v2/admin/autoscan/scans?limit=20`; `POST /api/v2/libraries/{id}/check-mount`; `POST /api/v2/libraries/{id}/refresh-metadata` (body `mode`: `quick` or `full`); `GET /api/v2/admin/jobs?kind=library_refresh&limit=50`; `POST /api/v2/admin/jobs/{id}/cancel` |
| Job history | `GET /api/v2/admin/jobs` (cursor paged, `limit` 1 to 200, 20 used) |
| Nodes | `GET /api/v2/admin/nodes/summary` (paged, 200 used); `GET /api/v2/admin/nodes` (read only for `config_etag`); `POST /api/v2/admin/nodes/{id}/drain|resume|check`; `PUT /api/v2/admin/nodes/{id}` with `{"enabled": …}` and `If-Match` = `config_etag` |
| Backups | `GET /api/v2/admin/backups`; `POST /api/v2/admin/backups` (202; 409 while the lock is held); `DELETE /api/v2/admin/backups/{id}` (204); `PUT /api/v2/admin/settings/backup.enabled|backup.time|backup.keep` with the `ETag` of `GET /api/v2/admin/settings/effective` as `If-Match`, re-read between writes |
| Plugins | `GET /api/v2/admin/plugins/installations` (paged, 200 used); `POST …/installations/{id}/restart|update`; `PUT …/installations/{id}` with `{"enabled": …}` |
| Requests | `GET /api/v2/admin/requests/capabilities` (once per page; `available: false` is the unavailable page); `GET /api/v2/admin/requests?view=&q=&media_type=&requested_by_user_id=&cursor=&limit=` (50 per page, the route's maximum); `GET /api/v2/admin/requests/counts`; `GET /api/v2/admin/requests/{id}/events`; `POST /api/v2/admin/requests/{id}/approve|decline|retry|cancel` (bulk triage sends the per-request `approve` or `decline`, four at a time, each to the request's own server) |
| Requests menu badge | `GET /api/v2/admin/requests/counts` every 60 s while the app is in the foreground, summed over the servers in view; a server answering `dependency_unavailable` or `permission_denied` is not asked again until a pull to refresh |
| Users | `GET /api/v2/admin/users`; `GET|PUT|DELETE /api/v2/admin/users/{id}` (`If-Match` on writes); `POST /api/v2/admin/users` |
| Sessions & devices | `GET|DELETE /api/v2/admin/users/{id}/login-sessions`; `DELETE .../login-sessions/{sid}`; `GET /api/v2/admin/users/{id}/devices` (list only) |
| Reset password, temporary password | `POST /api/v2/admin/users/{id}/password-reset` with `{"delivery":"email"}` or `{"delivery":"link"}` (the link comes back once in `reset_url`; gated on `password_reset_link`); a temporary password is `PUT /api/v2/admin/users/{id}` with `password` and `require_password_change` (`If-Match`) |
| Profiles tab (gated on `profile_management`) | `GET|POST /api/v2/admin/users/{id}/profiles`; `PATCH|DELETE /api/v2/admin/users/{id}/profiles/{profile_id}` (no `If-Match`: the route is not guarded). `{"pin":null}` clears a PIN and the app sends it explicitly |
| User page: Watching now | `GET /api/v2/admin/sessions?user_id=` (rows of other accounts are dropped on the device as well) |
| API keys | `GET /api/v2/admin/api-keys?limit=50[&cursor=]`; revoke is `GET /api/v2/admin/api-keys/{id}` (its `ETag`) then `DELETE` with `If-Match` |
| Invitations | `GET|POST /api/v2/admin/invitations`; `POST /api/v2/admin/invitations/{id}/resend`; `DELETE /api/v2/admin/invitations/{id}` |
| Settings | `GET /api/v2/admin/settings/effective` (its `ETag` is the validator), `GET /settings/restart-keys`, `GET /settings/sensitive-status`; `PUT /api/v2/admin/settings` (`If-Match`; the answer carries the saved values, `restart_required` and the new `ETag`); `PUT /api/v2/admin/settings/{key}` (Other settings); `GET/PUT /api/v2/admin/request-settings` (`If-Match`); `GET /api/v2/admin/server/status` (`restart_required_reasons`); `POST /api/v2/admin/server/restart` (`restart_requested` or `already_requested`); tests: `POST /admin/email/test`, `POST /admin/settings/check/{kind}`, `POST /admin/notifications/server-channels/{id}/test`, `POST /admin/plugins/installations/{id}/auth-binding/test`; Network access: `GET /api/v2/network-access/capabilities`, `GET\|POST /admin/network-access/{provider}/status\|connect\|disconnect` |
| Audit | `GET /api/v2/admin/logs/audit[?cursor=][&user_id=]` |
| Logs | `GET /api/v2/admin/logs/app[?cursor=][&level=][&q=]` |
| Organization mode: gate lookup; contexts | `GET /api/bloem/v2/organizations` (account token) |
| Organization mode: pass | `POST /api/bloem/v2/admin/session` (account token; body `{"scope":"organization","organization_id":…}`) |
| Organization Overview | `GET /api/bloem/v2/admin/organization/overview` (pass) |
| Organization People | `GET .../organization/people[?query&status&group_id&sort&active_since&cursor&limit]`; `GET .../people/{account_id}`; `PATCH .../people/{account_id}/memberships/current`; `PATCH .../people/{account_id}/profiles/{profile_id}` |
| Organization bulk | `POST .../people/selections`; `POST .../people/bulk-jobs`; `GET .../people/bulk-jobs/{job_id}` |
| Organization Access groups | `GET|POST .../groups`; `PUT|DELETE .../groups/{id}` (revision in the body) |
| Organization Libraries & Entitlements | `GET .../libraries`; `PUT|DELETE .../entitlements/{folder_id}` |
| Organization Invitations | `GET|POST .../invitations`; `POST .../invitations/{id}/resend`; `DELETE .../invitations/{id}` |
| Organization Activity & Audit | `GET .../activity[?cursor]` |
| Organization Policy Cohorts | `GET .../entitlement-cohorts[?include_archived=true]` |
| Organization Policy Decisions | `GET .../policy-decisions[?cursor&limit]`; `GET .../policy-decisions/{id}` |
| Organization support: capabilities | `GET .../support-capabilities` (pass); `GET /api/bloem/v2/capabilities` (feature token `organization_support_v1`) |
| Organization support: reset link | `POST .../people/{account_id}/password-reset` |
| Organization support: sign-ins and devices | `GET|DELETE .../people/{account_id}/sessions`; `DELETE .../people/{account_id}/sessions/{session_id}`; `GET .../people/{account_id}/devices`; `DELETE .../people/{account_id}/devices/{device_id}` |
| Organization support: profiles | `POST .../people/{account_id}/profiles`; `PATCH .../profiles/{profile_id}/details`; `DELETE .../profiles/{profile_id}/pin`; `DELETE .../profiles/{profile_id}` (revision in the body) |
| Organization Streams | `GET .../streams[?limit&cursor]`; `POST .../streams/{session_id}/stop`; `POST .../streams/{session_id}/message` |
| Support Access (server Owner) | `POST /api/bloem/v2/admin/session` with `support` (`reason`, then `access_id`); `DELETE .../support-access`; platform pass `{"scope":"platform"}` for `GET /api/bloem/v2/admin/platform/organizations?status=active[&query&cursor&limit]`; owner check `GET /api/v2/account/me` and `GET /api/v2/admin/users/{id}` |
| Platform › Organizations | `GET /api/bloem/v2/capabilities` (shown on a Bloem server); platform pass `{"scope":"platform"}`; `GET /api/bloem/v2/admin/platform/organizations[?query&status&cursor&limit]`; `GET .../organizations/{id}`; `GET .../organizations/{id}/memberships[?cursor&limit]`; `POST .../organizations/{id}/suspend|reactivate` (`expected_revision`); `GET .../organizations/{id}/entitlement`; `POST .../organizations/{id}/entitlement/dry-run|apply`; `GET /api/bloem/v2/admin/platform/entitlement-templates?status=enabled`; owner name fallback `GET /api/v2/admin/users/{id}` |
| Organization Overview owner | `GET /api/bloem/v2/admin/organization/people/{account_id}` (context pass) |
| Tenants (no longer shown, not called) | `GET /api/bloem/v2/admin/platform/tenants`; `GET /api/bloem/v2/admin/platform/tenants/{tenant_id}/members` |

The old Tenants screens and their two calls are kept in the source but nothing shows or calls them: Platform ›
Organizations (2.10) replaces them.

**Guards.** `APIPathGuardTests` fails when a `"/api/` literal sits outside `Networking/API/` and
`Networking/AuthAPI.swift`, or when any v1 path other than `/api/v1/health` is added.
`APIContractTests` calls every `func` in those files once through the URL protocol stub and checks
each request against `BloemAdminTests/Resources/api-contract.json`: the method and path match an
operation (templates matched segment by segment), every query parameter is declared for it, every
required one is sent, every numeric value is within the parameter's declared `minimum`/`maximum`
(for example `limit` is at most 50 on requests), and a required body is present and non-empty
JSON. A source scan fails the test when a function has no case, so a new call must be added to it.
The contract file is generated, not edited: save the Silo server's v2 OpenAPI document and the Bloem server's as
`silo_v2.json` and `bloem_v2.json` (anywhere) and run
`python3 -I scripts/extract-api-contract.py silo_v2.json bloem_v2.json BloemAdminTests/Resources/api-contract.json`.

### 3.3 Live updates and paging

There are no polling timers, with one exception that is deliberate: an organization's Now playing on a server without the organization live socket (below). `Realtime/LiveConnection` is the one connection to a server's events socket
(`/api/v2/events/ws`, `silo.events.v2`); `LiveHub` holds one per server and follows the scenes. A screen subscribes to the
channels it shows with `.liveRefresh` (or `.liveRefreshAll` for All servers), reads once when it opens, and reads the REST
endpoint again when the channel says something changed. The socket is a cue, never data. The contract is
[design.md](design.md#live-updates).

| Screen | Channels | Reads |
|---|---|---|
| Now playing, a user's Watching now, Dashboard's Now playing | `sessions` | on open, on each cue |
| Libraries | `scans`, `jobs` | on open, on each cue |
| Scheduled tasks | `tasks` | on open, on each cue |
| Organization Now playing, People, Activity | `org.streams`, `org.people`, `org.activity` on the organization live socket (below) | on open, on each cue; without the socket, on open (Now playing every 10 s, as it always has) |
| Backups | `tasks`, `jobs` | on open, on each cue |
| Scan and backup Live Activity (`JobActivityFollow`) | `scans`, `jobs`, `tasks` | foreground only, on each cue |
| Dashboard's other sections, Nodes, Plugins, Playback history, Requests, Users, Server, Organizations | none | on open, on return to the foreground, on pull to refresh (Dashboard's slow tier at most every 5 min) |
| The Requests menu badge | none (the `notifications` channel is the requester's own inbox) | on open, on return, on server change, after answering a request |
| Widget counts (`SnapshotSync`) | none | on open and on return; widgets keep their own timeline |
| Audit, Logs, Invitations, Sessions & devices | none | on open, on filter, on pull; Audit/Logs: cursor-based **Load more** |

Connection rules, all in `LiveConnection` and covered by `LiveConnectionTests`:

- Foreground only: it connects when a scene is active and a screen wants a channel, and closes 10 s after either stops.
  Coming back after 10 s or more replaces the socket instead of trusting it.
- Reconnect with exponential backoff and full jitter (1, 2, 4 … 60 s); at once when `NWPathMonitor` reports a new path, when
  the app returns, after the server's own five-minute connection limit, and (once) after `access_changed`.
- Watchdog: Silo sends no heartbeat frame, so the client pings after 25 s of silence and declares the socket dead at 60 s
  without any frame or pong.
- Resume: Silo's protocol has no sequence numbers or replay, so each connect and each new channel is followed by the
  server's snapshot, which the screens treat as "read everything again". A subscribe frame replaces the whole set and there
  is no unsubscribe, so dropping a channel is a smaller subscribe.
- Fallback: only after three failed connects in a row, or on a server with no socket (404, 405, 501, a plain HTTP address),
  or for a channel the server does not offer this account, the visible screen is read at most once a minute, until the
  socket is back. Nothing is read in the background.
- Signals are collapsed: a burst of events is one read, and reads caused by signals are at least a second apart.

**The organization live socket.** Organization pages are authorized by the context pass, which an account ticket cannot
express, so they do not use the events socket above. A Bloem server that advertises `organization_live_v1` in
`GET /api/bloem/v2/capabilities` serves its own socket (`bloem-live.v1`, see [design.md](design.md#live-updates)). The app keeps
`LiveConnection` for it: `LiveHub.organizationConnection(for:)` holds one per organization and server, and
`OrganizationLiveSocket` carries the frames into the dialect the connection already speaks, so the foreground, backoff,
watchdog and fallback rules above apply unchanged.

- **Ticket and connect.** `OrganizationLiveConnector` mints a 30-second single-use ticket with the pass
  (`POST /api/bloem/v2/admin/organization/live/ticket`; `OrganizationSession.read` renews a stale pass and asks once more)
  and opens `GET /api/bloem/v2/organization/live/ws` with `bloem-live.v1, ticket.<ticket>` in the subprotocol, never in a
  URL. The ticket lists the channels the server serves; that list is the connection's hello.
- **Subscribing.** Nothing is sent before a subscribe. A page subscribes to the one channel it shows, only if the ticket lists
  it, and the adapter sends the difference as `subscribe` and `unsubscribe`. Every resync is a snapshot, so the first is the
  page's catch-up and a later one (a burst the server folded, a lost signal) is a read like any change. Heartbeats are frames
  that say nothing but feed the watchdog. Item ids are not used: the page reads its list again, at most once a second.
- **Close codes.** 4401, 4403 and 4408 become Silo's "access changed" (one new ticket at once; the mint renews the pass or
  answers 401, and a repeat backs off), 1012 reconnects at once, 4429 and the rest back off. After three failures in a row
  the visible page reads once a minute until the socket is back.
- **Pages.** `OrganizationLive.follow` is what a page calls: with the socket it reads on open and on each change; without it,
  or for a channel the ticket does not list, the page keeps what it did. Now playing keeps its 10-second loop (a server
  without the socket runs `poll` itself; a socket that does not serve `org.streams` runs the same pace on the connection's own
  per-subscription timer, `LiveWhenNotOffered.every`). People and Activity keep reading on open and on pull.
  `LiveWhenNotOffered` is the screen's rule while its channel is not served; the default is the minute every other channel gets.

Activity's open-time reload keeps pages you have loaded past the first. The Logs search box is debounced by 400 ms; the
Activity and Audit user-id filters apply when you tap **Filter**.

### 3.4 Settings the app exposes

Bloem Admin has **no settings screen of its own**:

| Behaviour | Controlled by |
|---|---|
| Light / dark appearance | The system setting |
| Tab bar (compact) vs sidebar (regular width) | `horizontalSizeClass`: iPhone portrait → `TabView`; iPad and wide layouts → `NavigationSplitView` |
| App lock | Always on; a device without passcode or biometrics stays locked |
| Language | English; `Localizable.xcstrings` is the catalog |
| Poll intervals, timeouts, page sizes | Constants (3.1, 3.3) |
| Test-only launch arguments | `--ui-testing-reset`, `--ui-testing-auth=…` — compiled into Debug builds only (1.7) |

### 3.5 Diagnostics and logging

The app writes **no log file**, sends **no analytics** and prints no tokens, passwords or request
bodies. For diagnosing a problem:

- **On-screen messages** — server-supplied text is shown verbatim; a failed page's title names the kind of
  failure and its text carries the underlying message.
- **The server's own logs inside the app** — the **Logs** tab (operational log, level filter,
  search) and the **Audit** tab (every request with status code; filter by your own user id to see
  exactly what the app sent).
- **Xcode console** when running from Xcode, for crashes and system messages.
- **CI artifacts** — every workflow run uploads `.xcresult` bundles, build/analyze logs, the
  unsigned archive and the printed privacy manifest, retained for 14 days (1.8).

### 3.6 Security model in one place

- HTTPS only, enforced three times: the address validator, `APIClient`, and App Transport Security.
  HTTP redirects are refused (2.1).
- One combined credential record per server in the Keychain with `WhenUnlockedThisDeviceOnly`;
  passwords never stored (2.5).
- Biometric/passcode lock at launch and on every return from inactive/background, fail-closed on a
  device without authentication, with a shield window over the snapshot (2.7).
- The app cannot impersonate a user (2.6).
- Stale responses cannot act on a newer session: every request is tagged with a credential
  generation and a 401/403 from an old generation is ignored (2.4).
- Settings, schedule and user writes carry `If-Match` and are never replayed, and every detail
  screen allows one in-flight privileged action at a time (3.1).
- Destructive actions — Delete User, Disable Account, Stop Playback, Terminate Session, Cancel Job,
  Restart Server, Revoke session / invitation / all sessions, Remove Server, Decline /
  Cancel request — are behind confirmation dialogs, and the most serious ones give a success haptic
  only after the server confirms.
- Invitation links copied with **Copy Link** go onto a **local-only** pasteboard entry that expires
  after ten minutes (no Universal Clipboard hand-off); **Share Link** is the explicit way to move a
  link off the device.
- Signed-out servers keep no credential; removed servers keep nothing.
- Nothing outside the app shows a token or personal data. The background check, the widgets and the control read no stored
  sign-in (the code is in separate files a unit test scans); notifications and widgets carry server names, reachability
  and two counts only, and a lock screen shows only the server's name unless "Show details on the lock screen" is on
  for that device ([platform-features.md](platform-features.md)).

### 3.7 Upgrading the app

Install a new build with the same bundle identifier and team (1.6). Data has one schema — a JSON
array of `{id, baseURL, displayName}` plus one versioned Keychain record per server — and a build
that fails to decode the array starts with an empty list and an explanatory alert rather than
crashing. Upgrading from a build that used the two legacy Keychain items migrates them on first use
(2.5). Changing the bundle identifier orphans the old data; users must re-add servers.

---

## Part 4 — Troubleshooting

### 4.1 Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| *The server address must use HTTPS.* | Address typed with `http://` | Put the server behind HTTPS; the app cannot use plain HTTP |
| *Enter only the server origin, without a path, query, or fragment.* | Address includes `/admin`, `/api`, a `?` or a `#` | Enter only `https://host[:port]` |
| *Could not reach that server.* when adding | Untrusted certificate, an HTTP redirect from a proxy, wrong host/port, no route, or a denied Local Network permission | Open the URL in Safari on the device first; point the app at the final origin (no redirect); check **Settings → Privacy & Security → Local Network** |
| *This server is not compatible with Bloem Admin.* | `/api/v1/health` has no `server_id` | Upgrade the server; the app requires a health identity |
| *That address isn't a Silo server. Check it and try again.* | The URL answers but not with a Silo server's API (web page, proxy error page) | Use the server's base URL with no path |
| Server's `403` message on **Connect** | Signed in with a viewer account | Add the server with an administrator account |
| **No Admin Access** | An account that was an administrator has been demoted and administers no organization either | Tap **Retry** if the role was just restored; otherwise remove the server and add it with an admin account |
| An organization administrator sees only the organization's pages | The account is not the server's administrator; the gate admitted it by its administrator membership (2.8) | Expected; sign in with the owner account for the platform pages |
| *This organization is suspended…* / *You no longer administer this organization.* / *You don't have access to this organization.* | The server answered `403 organization_suspended`, any other `403`, or `404` for the pass (2.8) | Not an app fault: the server owner reactivates the organization or restores the role. The organization leaves the choice meanwhile |
| An organization the owner administers is missing | A platform administrator only gets organizations they are an **active member** of; the session route answers 404 otherwise (2.8) | The server Owner opens it from **Support Access** with a reason (2.9), or the organization adds the owner as a member |
| **Support Access** is not in the menu | The account is not the server Owner, or the server does not advertise `organization_support_v1` (2.9) | Sign in as the Owner; update the server |
| *This person is an administrator. Only the organization's owner can help another administrator.* (or *…the organization's owner…*) | `409 target_protected`: the server's rule of who may act on whom (2.9) | Not an app fault: the owner helps administrators; the platform operator helps the owner |
| *Too many support actions in a short time…* | `429 rate_limited` from the support budgets; refused attempts count too (2.9) | Wait the time shown |
| *Someone else changed this just now…* / *This organization changed…* | A write found a stale pass or a revision conflict (2.8); it was not applied | Look at the reloaded page and ask again |
| **Incompatible Server Response** | The status probe answered with something the app cannot decode (proxy page, wrong product) | Fix the address or proxy; tap **Retry** |
| **Sign In Required** on every open | Refresh token missing/revoked, or sessions revoked on the server | Sign in once; if it recurs, check the user's sessions on the server |
| All Servers section shows *Sign in again to <server>…* | That server's token expired; the aggregate view does not silently refresh | Sign in inline; the section reloads |
| A section in All Servers shows an error with **Retry** | That server timed out (10 s) or is down | Tap **Retry** or pull to refresh; the other servers are unaffected |
| Lock screen says *Turn on a passcode, Face ID or Touch ID…* and **Try again** does nothing | No passcode and no Face ID / Touch ID enrolled on the device | Set a passcode (and optionally biometrics); the app will not run without one |
| Face ID prompt appears repeatedly | Every return from Control Centre / app switcher re-locks by design | Expected |
| **Saved Data Could Not Be Updated** at launch | The stored server list could not be decoded or written | Read the message; re-add servers if the list is empty |
| An action button is greyed out | Another action on that screen is still in flight | Wait for the first action to finish |
| **Tenants** tab missing | Replaced by Platform › Organizations (2.10) | Expected on every server |
| **Platform → Organizations** missing | The server did not answer `GET /api/bloem/v2/capabilities` (a plain Silo server, or one that was unreachable when the server opened) | Open the server again; check it is a Bloem server |
| *This server needs a newer version of Bloem Admin.* | The server answered `410 client_upgrade_required` | Update the app |
| *… changed on the server after you opened it. Your edit is kept.* | Another administrator saved the same user or schedule first (`412`) | Tap **Review Current …**, then keep your edit or discard it |
| *Settings changed on the server* | Any setting changed after you started editing (`412`; the validator covers the whole settings snapshot) | Choose **Keep my changes** (save over the server's values) or **Use the server's values**; Other settings' editor offers **Use Current Value** and **Keep My Edit and Continue** |
| *Password sign-in can't be turned off yet…* | `409 break_glass_required`: no admin is a break-glass account | Turn on Break-glass account on an admin's user page, then save again |
| A test shows **Failed** | The provider answered and refused (the server's reason is shown) | Fix the setting the reason names; nothing was changed by the test |
| *The test could not run* | The request did not reach the server | Check the connection and try again; a test is never repeated for you |
| *The server did not send a version for its settings…* | `GET /api/v2/admin/settings/effective` came back without an `ETag` | Update the server |
| The host line under **Server health** missing from Dashboard | `GET /api/v2/admin/system/resources` answered `available: false` (a host that cannot be sampled) | Expected |
| **Egress now** tile missing | The newest `timeseries?hours=1` sample is more than two minutes old, or has not arrived | Expected while the metrics sampler is behind; the tile returns with the next fresh sample |
| A failure page (*Can't reach the server*, *No access*, *Server error 500*…) on one tab only | That tab's list request failed; others still work | **Try again**, or pull to refresh; check the server |
| Build error "No such module" or missing files after `git pull` | Stale generated project | `xcodegen generate` |
| CI job **Generated project is current** fails | `.xcodeproj` was edited in Xcode or not regenerated after a `project.yml` change | Run `xcodegen generate` with 2.46.0 and commit the result |
| CI build fails on a warning | Swift 6 strict concurrency diagnostic; CI treats warnings as errors | Fix the warning locally with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| "Signing for BloemAdmin requires a development team" | No `DEVELOPMENT_TEAM` in the project | Pick a team in Signing & Capabilities, or add it to `project.yml` |
| Servers gone after restoring a backup to a new phone | Keychain items are `ThisDeviceOnly` | Re-add the servers (the list entries may still be there; use Sign In Required to re-authenticate, or remove and re-add) |

### 4.2 Known gaps in the current code

- **The string catalog is partly behind the views.** `Localizable.xcstrings` holds 206 keys and
  now covers the Dashboard, Logs and Invitations screens (guarded by
  `StringCatalogTests`); literals in the quota and schedule editors and parts of Users and Streams
  have still not been extracted, so a translation pass should first build once with
  `SWIFT_EMIT_LOC_STRINGS` to refresh the catalog for those.
- **Task and job progress is a cue, not data.** The events socket (`Realtime/`) says that a task changed and the page reads
  the list again, so the percentage is current. The server's
  `progress_message` is sent on the socket only, so the task page's **Progress** line stays empty from REST;
  the percentage from REST does fill the bar. A longest run is editable on daily and weekly triggers, not on
  interval or startup triggers (their saved value is kept).
- **Nodes, Backups and Plugins stop short of setup.** Adding, editing or deleting a node, restoring or
  uploading a backup, the S3 destination, the plugin catalogue, repositories and plugin settings stay on the
  web admin. Organization mode has none of these pages.
- **Request actions follow the view.** The queue offers Approve and Decline on Needs approval, Cancel
  request while nothing was sent for an in-progress request, and Retry and Cancel request (close) on
  Failed (`RequestQueue.actions(for:)`, the web's rules); the server still checks, and a refusal is shown
  above the queue.
- **Bulk triage answers only what is loaded.** Select all picks the requests on screen (up to what **Load
  more** has brought in), not the whole queue, and an approval carries no note because the server takes
  none.
- **API keys are listed and revoked, not created.** Creating a key shows its secret once and is left to
  the web admin, as are rate tiers. The page exists for one server at a time, not All servers.
- **Emptying a quota field sends no change.** The **Inherit** toggles are the way to clear an
  override; blanking **Max Streams**, **Max Transcodes** or **Max Profiles** leaves the stored value
  as it is.
- **Organization support needs a current server.** Reset links, sign-outs, profile edits, Streams and Support Access
  appear only on a server that advertises `organization_support_v1` (2.9); an older server shows none of them and the
  person page says what it cannot do. Policy jobs, setting a PIN and parental fields are not organization authority on
  any server.
- **Support access is remembered for one run only.** Reopening an organization within its four hours reuses the access
  while the app keeps running; after a restart the Owner states a new reason, which opens a new access (the old one runs
  out on its own).
- **Device revoke is not offered, and Tenants is not shown.** The v2 API has no device revoke, and Platform ›
  Organizations (2.10) replaces the Tenants screens.
- **Platform › Organizations is read-and-switch only.** It lists, shows, suspends, reactivates and changes the plan.
  It does not create or rename an organization, transfer ownership, change a member's role or status, add a member,
  edit branding or domains, or show the plan change history; use the web admin for those.
- **No OIDC or other single sign-on.** Sign-in is username and password only.
- **No signed distribution in CI.** The workflow produces an unsigned archive only; TestFlight and
  ad-hoc exports are manual (1.6).
- **Physical-device checks remain manual.** Real Face ID / Touch ID / passcode behaviour, Keychain
  access while the device is locked, app-switcher snapshots with the keyboard up, two live iPad
  windows, VoiceOver and Local Network permission handling are operator checks before each release.

---

## Glossary

- **Access token** — a short-lived credential sent with every request; expires and is refreshed.
- **Admin gate** — the check made when opening a server (`GET /api/v2/admin/server/status`).
- **All Servers** — the aggregate view that shows every added server's data in sections.
- **App Transport Security (ATS)** — the iOS policy that blocks non-HTTPS connections.
- **Bundle identifier** — the app's unique id (`com.bloemstudios.admin`); tied to signing.
- **Credential generation** — a counter per server that increases on every login, refresh or
  token change; responses from an older generation are ignored.
- **ETag / If-Match** — a version tag the server returns with a setting, schedule or user; sending
  it back with a write makes the server refuse (`412`) if someone else changed it meanwhile.
- **Keychain** — iOS's encrypted credential store.
- **Origin** — scheme + host + port with nothing after it (`https://host:8090`).
- **Refresh token** — a single-use credential exchanged for a new access token without a password.
- **Scene** — one window of the app; iPad can show several at once, each with its own lock state.
- **Scene phase** — whether a scene is active, inactive or in the background; drives locking and polling.
- **Shield window** — the extra window the app places over its content while locked so nothing
  leaks into the app-switcher snapshot.
- **Tenant** — an older word for an organization on the server; the app's old Tenants screens are no longer shown.
- **XcodeGen** — the tool that turns `project.yml` into `BloemAdmin.xcodeproj`.

## Source References

- `project.yml`, `BloemAdmin.xcodeproj/project.pbxproj`, `BloemAdmin.xcodeproj/xcshareddata/xcschemes/BloemAdmin.xcscheme` — targets, bundle ids, deployment target, Swift 6 / strict concurrency, signing identity, scheme
- `.github/workflows/ci.yml` — the four CI jobs, Xcode 26.6, XcodeGen 2.46.0 pin, destinations, artifacts
- `BloemAdmin/Info.plist`, `BloemAdmin/PrivacyInfo.xcprivacy` — version, Face ID and local-network usage strings, launch screen, orientations, absence of ATS exceptions, privacy manifest
- `BloemAdmin/App/BloemAdminApp.swift`, `AppLockState.swift`, `LockScreenView.swift`, `AdminSessionState.swift` — scene shield, lock state machine, fail-closed behaviour, expiry state, credential generations
- `BloemAdmin/Networking/ServerEndpointValidator.swift`, `ProductionSession.swift`, `APIClient.swift`, `APIError.swift` — origin rules and messages, session timeouts and redirect refusal, HTTPS guard, `If-Match` writes, error mapping
- `BloemAdmin/Networking/ServerCredentials.swift`, `KeychainStore.swift`, `SecurityClient.swift`, `ServerFanOut.swift` — combined credential record, accessibility class, legacy migration, per-server locks, fan-out timeout
- `BloemAdmin/Servers/ServerStore.swift`, `AddServerView.swift`, `AdminGateView.swift`, `ManageServersView.swift`, `AllServersView.swift` — UserDefaults key, enrollment steps, gate outcomes, tabs, aggregate view, persistence alert
- `BloemAdmin/Jobs/AdminTask.swift` — `PrivilegedMutationGate`, schedule validation messages
- `BloemAdmin/Jobs/TaskRowPresentation.swift`, `HistoryPager.swift`, `TimedTriggerDraft.swift` — row status, paged history, daily and weekly trigger rows
- `BloemAdmin/Shell/SectionModel.swift`, `SectionPageViews.swift`, `Nodes/`, `Backups/`, `Plugins/` — the Nodes, Backups and Plugins pages (one `SectionModel` per server; All servers fans out)
- `BloemAdmin/Shell/AutomationUITestFixture.swift` — debug-only fake server for the UI tests of these pages (`--ui-testing-automation=tasks|nodes|backups|plugins`)
- `BloemAdmin/Networking/API/*.swift`, `BloemAdmin/Networking/AuthAPI.swift` — every route in 3.2
- `BloemAdminTests/Networking/APIPathGuardTests.swift`, `APIContractTests.swift`, `BloemAdminTests/Resources/api-contract.json`, `scripts/extract-api-contract.py` — the path and contract guards
- `BloemAdmin/Invitations/InvitationsListView.swift` — local-only expiring pasteboard for invite links
- `BloemAdmin/Organization/*.swift`, `BloemAdmin/Networking/API/OrganizationAPI.swift` — contexts, the pass (`OrganizationSession`), the organization pages and their view models, the routes in 3.2
- `BloemAdmin/Organization/OrganizationUITestHost.swift`, `BloemAdminUITests/OrganizationUITests.swift` — the DEBUG stub server and the organization UI tests
- `BloemAdmin/Organization/OrganizationSupport*.swift`, `OrganizationPersonSupport*.swift`, `OrganizationStreams.swift`, `BloemAdmin/Networking/API/OrganizationSupportAPI.swift` — organization support: capabilities, reset links, sign-outs, profiles, streams, the support banner (2.9)
- `BloemAdmin/SupportAccess/*.swift` — the server Owner's Support Access page and its platform pass (2.9); `BloemAdminUITests/OrganizationSupportUITests.swift`
- `BloemAdmin/*/…ViewModel.swift` — every endpoint in 3.2, page sizes
- `BloemAdmin/*/…View.swift` — `.liveRefresh` / `.liveRefreshAll` (channels per screen)
- `BloemAdminUITests/BloemAdminSmokeTests.swift` — the five UI smokes and their launch arguments
- `BloemAdmin/Localizable.xcstrings` — string catalog
- `README.md`, `docs/design.md`, `docs/releasing.md` — the overview, the look and push rules, and how a release is cut
