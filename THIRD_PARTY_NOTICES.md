# Third-party notices

Bloem Admin is licensed under the GNU AGPL v3 (see [LICENSE](LICENSE)). It includes or depends on the following.

## Bundled in the repository

| Material | Where | Licence |
|---|---|---|
| Plus Jakarta Sans (font) | `BloemAdmin/Resources/Fonts/PlusJakartaSans-Variable.ttf` | SIL Open Font License 1.1: [LICENSES/PlusJakartaSans-OFL.txt](LICENSES/PlusJakartaSans-OFL.txt) |
| Lucide icons, as SVG template images | `BloemAdmin/Resources/Icons.xcassets`, `BloemAdminWidgets/Icons.xcassets` and the app icon sources in `docs/design/app-icons/` | ISC: [LICENSES/Lucide-ISC.txt](LICENSES/Lucide-ISC.txt) |

The OFL asks that the font's copyright notice and licence travel with it. This file and the licence text in `LICENSES/` do
that for the source. A build that bundles the font should also show the notice somewhere a user can reach.

## Libraries compiled into the app

None. The app uses Apple's frameworks only (SwiftUI, WidgetKit, ActivityKit, UserNotifications, LocalAuthentication,
Security and URLSession). There are no Swift packages, no CocoaPods and no vendored code.

## Used only to build and test

[XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) generates the Xcode project from `project.yml`. It is not part of
the app. The icon and colour scripts in `scripts/` and `docs/design/app-icons/` use Python, and some use Pillow, NumPy,
SciPy and scikit-image, which are installed separately.

## Services the app contacts

- **Your servers.** Everything the app sends goes to the Silo or Bloem servers you add.
- **Apple Push Notification service.** In the official build, a Bloem server can push to the phone through Apple's service.
  A build you make yourself does not use it.

## Names and marks

The Bloem name and tulip logo are trademarks of Bloem Studios. They appear in the app icon and in the icon source files
under `docs/design/app-icons/`. The AGPL covers the code and does not license the marks. If you distribute a modified
build, give it a different name and icon, and your own bundle identifiers. Silo and other product names belong to their
owners and are used only to say which servers the app works with.
