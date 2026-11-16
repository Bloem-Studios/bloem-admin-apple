import SwiftUI

// Shared pieces of the organization pages: a banner for the last message, a status pill, a layout that wraps its
// children onto further lines, and the date and plural words every page uses.

/// One message with a Dismiss. Errors speak up to assistive technology at once; confirmations do too, politely.
struct OrganizationMessageBanner: View {
    let text: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconImage(isError ? .triangleAlert : .circleCheck, size: .inline)
                .foregroundStyle(isError ? Theme.danger : Theme.ok)
                .accessibilityHidden(true)
            Text(text)
                .bloemText(.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .bloemText(.bodyMedium)
                .buttonStyle(.bloemQuiet)
                .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isError ? "organization-error" : "organization-notice")
    }
}

/// Lays children out left to right and wraps them onto further lines. The bulk bar uses it so its actions never
/// run off the edge of a narrow phone or grow into one tall column.
struct OrganizationFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum OrganizationText {
    /// `2026-11-12T09:30:00Z` as the device would write it; anything that does not parse is shown as sent.
    static func when(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        guard let date = parse(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func parse(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func people(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) person") : String(localized: "\(count) people")
    }

    /// A device as a person would name it: its own name, else "an unnamed device".
    static func deviceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "an unnamed device") : trimmed
    }

    /// The platform a device reported, as a readable name ("androidtv" is Android TV).
    static func platform(_ code: String) -> String {
        let names = [
            "android": "Android", "ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "macos": "macOS", "windows": "Windows",
            "linux": "Linux", "web": "Web", "androidtv": "Android TV", "tizen": "Tizen", "webos": "webOS", "roku": "Roku",
        ]
        return names[code.lowercased()] ?? code
    }

    /// How long until `date`, in hours and minutes ("3 hr, 12 min"), and nothing once it has passed.
    static func timeLeft(until date: Date, now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        // Round up: "1 min" until the last minute is over.
        return formatter.string(from: max(60, (seconds / 60).rounded(.up) * 60))
    }

    static func members(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) member") : String(localized: "\(count) members")
    }

    static func libraries(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) library") : String(localized: "\(count) libraries")
    }

    static func accounts(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) account") : String(localized: "\(count) accounts")
    }

    static func screens(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) screen") : String(localized: "\(count) screens")
    }

    static func profiles(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) profile") : String(localized: "\(count) profiles")
    }

    static func conversions(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) conversion") : String(localized: "\(count) conversions")
    }

    /// An organization or membership status as the web words it.
    static func status(_ status: String) -> String {
        switch status {
        case "active": String(localized: "Active")
        case "suspended": String(localized: "Suspended")
        case "invited": String(localized: "Invited")
        case "initializing": String(localized: "Initializing")
        default: OrganizationVocabulary.sentenceCase(status)
        }
    }

    /// A suspended organization or member needs a look, an active one is good, the rest are neutral.
    static func statusTone(_ status: String) -> StatusLabel.Tone {
        switch status {
        case "suspended": .warning
        case "active": .positive
        default: .normal
        }
    }
}

/// The frame every organization list shares: the last message on top, a progress view while the first load runs,
/// and a failed or empty surface when there is nothing to list.
struct OrganizationListFrame<Rows: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let emptyTitle: String
    let emptyMessage: String
    let emptyIcon: BloemIcon
    let errorMessage: String?
    let noticeMessage: String?
    let onRetry: () -> Void
    let onDismissMessages: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        List {
            if let noticeMessage {
                Section { OrganizationMessageBanner(text: noticeMessage, isError: false, onDismiss: onDismissMessages) }
            }
            // A failure that leaves rows on screen is a banner; with nothing to show it becomes the page.
            if let errorMessage, !isEmpty {
                Section { OrganizationMessageBanner(text: errorMessage, isError: true, onDismiss: onDismissMessages) }
            }
            if !isEmpty { rows() }
        }
        .overlay {
            if isLoading && isEmpty {
                ProgressView("Loading…")
            } else if isEmpty, let errorMessage {
                BloemEmptyState {
                    Label("Couldn't load", icon: .wifiOff)
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try again", action: onRetry).buttonStyle(.bloemProminent)
                }
                .accessibilityIdentifier("organization-error")
            } else if isEmpty {
                BloemEmptyState(emptyTitle, icon: emptyIcon, description: Text(emptyMessage))
            }
        }
    }
}
