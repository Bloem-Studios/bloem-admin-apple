import SwiftUI

/// The icons Bloem Admin draws: Lucide (ISC licence, LICENSES/Lucide-ISC.txt), the one icon set of the six Bloem
/// staff apps. Each case is a Lucide icon name; its SVG sits in `Resources/Icons.xcassets` as `lucide.<name>`,
/// a template image that takes the colour of its text role. `scripts/lucide-icons.py` writes that catalog from
/// this list, so adding an icon is: add a case here, run the script, commit both.
///
/// No SF Symbols anywhere (`LookGuardTests` fails on a `systemName:` or `systemImage:` in the sources).
///
/// The shared names for shared concepts are in `docs/design.md`.
enum BloemIcon: String, CaseIterable, Sendable {
    case archive = "archive"
    case arrowLeftRight = "arrow-left-right"
    case arrowRight = "arrow-right"
    case ban = "ban"
    case bell = "bell"
    case building2 = "building-2"
    case calendar = "calendar"
    case calendarClock = "calendar-clock"
    case check = "check"
    case chevronDown = "chevron-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronUp = "chevron-up"
    case chevronsUpDown = "chevrons-up-down"
    case circle = "circle"
    case circleAlert = "circle-alert"
    case circleArrowRight = "circle-arrow-right"
    case circleCheck = "circle-check"
    case circleDot = "circle-dot"
    case circlePlay = "circle-play"
    case circlePlus = "circle-plus"
    case circleStop = "circle-stop"
    case circleUser = "circle-user"
    case circleX = "circle-x"
    case clipboardList = "clipboard-list"
    case clockAlert = "clock-alert"
    case clockCheck = "clock-check"
    case compass = "compass"
    case copy = "copy"
    case cpu = "cpu"
    case download = "download"
    case ellipsis = "ellipsis"
    case fileSearch = "file-search"
    case fileText = "file-text"
    case film = "film"
    case gitBranch = "git-branch"
    case history = "history"
    case inbox = "inbox"
    case info = "info"
    case keyRound = "key-round"
    case layers = "layers"
    case layoutDashboard = "layout-dashboard"
    case library = "library"
    case lifeBuoy = "life-buoy"
    case link = "link"
    case listFilter = "list-filter"
    case lock = "lock"
    case lockOpen = "lock-open"
    case logOut = "log-out"
    case mail = "mail"
    case mailPlus = "mail-plus"
    case menu = "menu"
    case messageSquareText = "message-square-text"
    case monitorPlay = "monitor-play"
    case network = "network"
    case octagonX = "octagon-x"
    case pencil = "pencil"
    case plus = "plus"
    case puzzle = "puzzle"
    case radio = "radio"
    case rotateCw = "rotate-cw"
    case scanFace = "scan-face"
    case scrollText = "scroll-text"
    case search = "search"
    case server = "server"
    case settings = "settings"
    case share = "share"
    case shieldCheck = "shield-check"
    case slidersHorizontal = "sliders-horizontal"
    case snowflake = "snowflake"
    case trash2 = "trash-2"
    case triangleAlert = "triangle-alert"
    case unplug = "unplug"
    case userRoundX = "user-round-x"
    case userX = "user-x"
    case users = "users"
    case usersRound = "users-round"
    case wifiOff = "wifi-off"
    case x = "x"

    /// The image's name in the asset catalog.
    var assetName: String { Self.assetPrefix + rawValue }

    static let assetPrefix = "lucide."
}

/// The three sizes an icon is drawn at, one per role. The artwork is 24 wide with a stroke of 2, so these
/// give a stroke of 1.33 (inline), 1.5 (rows and menus) and 1.67 (top bars).
enum IconSize: CGFloat, Sendable {
    /// Beside small text, in a caption or a chip.
    case inline = 16
    /// In list rows, menus and buttons. The catalog's own size, so a plain `Image` or `Label` icon is this.
    case row = 18
    /// In the top bar.
    case bar = 20
}

extension Image {
    /// The icon at its natural size (18, the row size). Use `IconImage` for the other sizes.
    init(icon: BloemIcon) {
        self.init(icon.assetName)
    }
}

/// An icon at one of the three sizes, in the colour of the surrounding text (`.foregroundStyle` changes it).
struct IconImage: View {
    let icon: BloemIcon
    let size: IconSize

    init(_ icon: BloemIcon, size: IconSize = .row) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(icon: icon)
            .resizable()
            .scaledToFit()
            .frame(width: size.rawValue, height: size.rawValue)
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == Image {
    /// A label with a Lucide icon, in place of `Label(_:systemImage:)`.
    init(_ titleKey: LocalizedStringKey, icon: BloemIcon) {
        self.init(titleKey, image: icon.assetName)
    }

    init<S: StringProtocol>(_ title: S, icon: BloemIcon) {
        self.init(title, image: icon.assetName)
    }
}
