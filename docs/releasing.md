# Releasing

This page describes how a TestFlight build is made. The maintainers hold the Apple account, so only they can publish the
official build. Nothing secret lives in this repository: the team, the App Store Connect key and the profiles all come from
the environment, outside git. The same script works for your own build under your own Apple account.

## Versions

A release is a git tag `vMAJOR.MINOR[.PATCH]`, for example `v1.2.0`. `scripts/testflight.sh` reads the tag on `HEAD` and
uses it as the marketing version (`1.2.0`) for the app and both extensions. It stops when `HEAD` has no such tag, unless
`MARKETING_VERSION` is set. It never creates or pushes a tag.

The build number is the UTC time as `YYYYMMDDHHMM`, so each run is higher than the last and App Store Connect accepts it. Two
builds in the same minute collide: wait a minute, or set `BUILD_NUMBER`. The app and both extensions get the same pair.

## What you need

- A Mac with Xcode and a paid Apple Developer Program team.
- The three App IDs under that team: the app, the widget extension and the notification service extension. Push
  Notifications is enabled on the app's App ID, and the App Group is enabled on all three. The identifiers are in
  `project.yml`; change them there if you build under your own team.
- An App Store Connect app record for the app's bundle identifier. The name must be free: Apple's names are first come, first
  served and limited to 30 characters.
- An App Store Connect API key with the App Manager role, so that Xcode can create and renew the signing certificate and
  provisioning profiles by itself. Download its `.p8` once and keep it outside any checkout, mode 0600.

| Environment variable | Meaning |
|---|---|
| `BLOEM_ADMIN_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `ASC_KEY_PATH` | Path to `AuthKey_<KEYID>.p8` |
| `ASC_KEY_ID` | The key's ID |
| `ASC_ISSUER_ID` | The issuer ID (a UUID) shown on the App Store Connect API page |
| `RELEASE_ENV_FILE` | Optional: a file of `KEY=value` lines (outside the checkout) the script reads first |

## Running it

From a clean checkout of the release tag:

```sh
scripts/testflight.sh --unsigned   # needs no Apple account: archive with signing off and check the result
scripts/testflight.sh --check      # check the tools and the environment, print the version and commands, build nothing
scripts/testflight.sh --no-upload  # archive and export a signed .ipa into build/export, but do not upload it
scripts/testflight.sh              # archive, sign, export and upload to App Store Connect
```

`--unsigned` is the check to run first. It checks the versions, the privacy manifests of the app and both extensions, the
encryption flag and the usage strings. App Store Connect processes an uploaded build for a few minutes, and then it appears
under the app's TestFlight tab.

## The first build

- **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false` in the app's Info.plist, because the app uses only the
  system's TLS, the Keychain, LocalAuthentication and a SHA-256 digest. App Store Connect should not ask again.
- **Testers.** Internal testers (members of the team) need nothing more than the build. External testers need a beta app
  description, a feedback address, contact details, what to test and a privacy policy URL, and the first external build goes
  through a short beta review.
- **Review needs a server.** The app is useless without one, so reviewers need an address and an administrator login. Use a
  throwaway sandbox server, never a production one.

## Signing

Automatic signing, with the team from `BLOEM_ADMIN_TEAM_ID`. `Config/Signing.local.xcconfig` is for builds in Xcode and is
git-ignored; the script does not read it.

An app signed under another team cannot replace the official one, and it does not receive push notifications: the push
credentials belong to the official build.
