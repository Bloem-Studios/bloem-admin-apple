import Foundation

/// What a push carries: a delivery id and nothing else. The relay never sees text. The id is
/// `{deviceID}.{delivery}`; the device id is what this app got when it registered with one saved server, so
/// it names which saved server the push is for.
struct PushWire: Equatable, Sendable {
    static let deliveryKey = "bloem_delivery_id"
    /// The server caps a wire id at 128 characters.
    static let maxLength = 128

    let deviceID: String
    let deliveryID: String

    /// The id the content route takes, exactly as pushed.
    var contentID: String { "\(deviceID).\(deliveryID)" }

    /// Reads a push's payload. Anything that is not a well-formed admin push is refused, not guessed at.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.deliveryKey] as? String else { return nil }
        self.init(raw: raw)
    }

    init?(raw: String) {
        guard !raw.isEmpty, raw.utf8.count <= Self.maxLength else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isPlain(parts[0]), Self.isPlain(parts[1]) else { return nil }
        deviceID = String(parts[0])
        deliveryID = String(parts[1])
    }

    private static func isPlain(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }
}

/// The text and behaviour of one notification, as `GET /api/bloem/v2/admin/push/content/{delivery_id}`
/// answers it. A server could send anything, so it is cleaned by `sanitized()` before it is shown.
struct PushContent: Decodable, Equatable, Sendable {
    let deliveryID: String
    let kind: String
    let title: String
    let body: String
    let lockScreen: String
    let page: String?
    let itemID: String?
    let subjectType: String?
    let actions: [String]

    // `badge` is in the server's answer too, and is ignored on purpose: the app icon's number is the relay's
    // count, which arrives in the push itself.
    private enum CodingKeys: String, CodingKey {
        case deliveryID = "delivery_id"
        case kind, title, body
        case lockScreen = "lock_screen"
        case page
        case itemID = "item_id"
        case subjectType = "subject_type"
        case actions
    }

    init(
        deliveryID: String = "", kind: String, title: String, body: String = "", lockScreen: String = "",
        page: String? = nil, itemID: String? = nil, subjectType: String? = nil, actions: [String] = []
    ) {
        self.deliveryID = deliveryID
        self.kind = kind
        self.title = title
        self.body = body
        self.lockScreen = lockScreen
        self.page = page
        self.itemID = itemID
        self.subjectType = subjectType
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deliveryID = try c.decodeIfPresent(String.self, forKey: .deliveryID) ?? ""
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        lockScreen = try c.decodeIfPresent(String.self, forKey: .lockScreen) ?? ""
        page = try c.decodeIfPresent(String.self, forKey: .page)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        subjectType = try c.decodeIfPresent(String.self, forKey: .subjectType)
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
    }
}

/// A notification's content after cleaning: text trimmed to one short line, a page the app has, and buttons
/// only on a request notice that names its request.
struct PushDisplay: Equatable, Sendable {
    let kind: PushKind
    let title: String
    let body: String
    let lockScreen: String
    let page: PushLinkPage?
    let itemID: String?
    let actions: [PushAction]

    static let maxText = 140
    static let maxItemID = 128
}

extension PushContent {
    /// The content cleaned up for display, or nil when there is nothing worth showing (a kind this build does
    /// not know, or no title).
    func sanitized() -> PushDisplay? {
        guard let kind = PushKind(rawValue: kind) else { return nil }
        let cleanTitle = Self.oneLine(title, limit: PushDisplay.maxText)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanPage = page.flatMap(PushLinkPage.init(rawValue:))
        let cleanItem = itemID.map { Self.oneLine($0, limit: PushDisplay.maxItemID + 1) }
            .flatMap { !$0.isEmpty && $0.count <= PushDisplay.maxItemID ? $0 : nil }
        // An item is only meaningful on a page the app has.
        let linkedItem = cleanPage == nil ? nil : cleanItem
        // A button needs the request it acts on.
        var buttons: [PushAction] = []
        if kind == .requestWaiting, linkedItem != nil {
            for raw in actions {
                if let action = PushAction(rawValue: raw), !buttons.contains(action) { buttons.append(action) }
            }
        }
        let lock = Self.oneLine(lockScreen, limit: PushDisplay.maxText)
        return PushDisplay(
            kind: kind, title: cleanTitle, body: Self.oneLine(body, limit: PushDisplay.maxText),
            lockScreen: lock.isEmpty ? kind.lockScreenText : lock,
            page: cleanPage, itemID: linkedItem, actions: buttons
        )
    }

    /// One line: control characters dropped, runs of white space made one space, cut at `limit` characters.
    static func oneLine(_ value: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let flat = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
