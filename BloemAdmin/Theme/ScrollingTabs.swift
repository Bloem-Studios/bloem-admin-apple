import SwiftUI

/// The one tab strip: a row of words that scrolls sideways. The chosen one is semibold on a soft selection
/// fill; the others are muted. User page tabs and the request queue's views both use it.
struct ScrollingTabs<Item: Hashable>: View {
    let items: [Item]
    let selection: Item
    let title: (Item) -> String
    var count: (Item) -> Int? = { _ in nil }
    let identifier: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(items, id: \.self) { item in
                        tab(item)
                            .id(item)
                    }
                }
            }
            .onChange(of: selection) { _, selected in
                proxy.scrollTo(selected, anchor: .center)
            }
        }
    }

    private func tab(_ item: Item) -> some View {
        let selected = item == selection
        return Button { onSelect(item) } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title(item))
                    .bloemText(selected ? .titleSmall : .bodyMedium)
                    .foregroundStyle(selected ? Color.bloemText : Color.bloemMuted)
                if let value = count(item) {
                    Text(value, format: .number)
                        .bloemText(.labelMedium)
                        .foregroundStyle(.bloemMuted)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.minimumTarget)
            .background(selected ? Theme.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier(item))
    }
}

/// The primary action: an accent fill with the on-accent label, reaching 4.5:1 in both appearances. The
/// system's `.borderedProminent` paints a white label, which is only 3:1 on dark-mode orange.
struct BloemProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bloemText(.titleMedium)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.minimumTarget)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

/// A secondary action: a raised fill with text-colour text, 44 tall. A destructive one is danger text.
struct BloemSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bloemText(.titleMedium)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.minimumTarget)
            .background(
                configuration.isPressed ? Theme.selected : Theme.raised,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A text action with no fill (Select, Done, Edit schedule): text colour in the medium weight, danger when it
/// destroys something. Orange is for the primary action and the current selection, not for every link.
struct BloemQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bloemText(.titleSmall)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .frame(minHeight: Theme.minimumTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == BloemSecondaryButtonStyle {
    static var bloemSecondary: BloemSecondaryButtonStyle { BloemSecondaryButtonStyle() }
}

extension ButtonStyle where Self == BloemQuietButtonStyle {
    static var bloemQuiet: BloemQuietButtonStyle { BloemQuietButtonStyle() }
}

extension ButtonStyle where Self == BloemProminentButtonStyle {
    static var bloemProminent: BloemProminentButtonStyle { BloemProminentButtonStyle() }
}
