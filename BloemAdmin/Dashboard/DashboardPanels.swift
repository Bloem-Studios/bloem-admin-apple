import SwiftUI

/// A titled card holding one dashboard section. The identifier is what UI tests use to find the
/// section and to check the order.
struct SectionPanel<Content: View>: View {
    let section: DashboardSection
    let title: LocalizedStringKey
    var caption: String?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title)
                        .bloemText(.titleMedium)
                        .accessibilityAddTraits(.isHeader)
                    if let caption {
                        Text(caption).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(actionTitle)
                            IconImage(.chevronRight, size: .inline).accessibilityHidden(true)
                        }
                        .bloemText(.titleSmall)
                        .foregroundStyle(.bloemMuted)
                        .frame(minHeight: Theme.minimumTarget)
                    }
                    .accessibilityIdentifier(section.identifier + "-action")
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .bloemCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(section.identifier)
    }
}

/// A refresh that failed; the last good value, when there is one, stays above it.
struct SectionErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, icon: .triangleAlert)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemWarn)
                .padding(.top, Theme.Space.xs)
        }
    }
}

struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .bloemText(.bodyMedium)
            .foregroundStyle(.bloemMuted)
            .padding(.top, Theme.Space.xs)
    }
}

/// A primary line with an optional second line and a trailing note, as the list sections use.
struct DashboardListRow: View {
    let primary: String
    var secondary: String?
    var trailing: String?
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(primary).bloemText(.bodyMedium)
                    if let secondary {
                        Text(secondary).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                .wrapsAtAnySize()
                Spacer(minLength: Theme.Space.s)
                if let trailing {
                    Text(trailing)
                        .bloemText(.bodySmall)
                        .foregroundStyle(warn ? Theme.warn : Theme.muted)
                        .multilineTextAlignment(.trailing)
                        .wrapsAtAnySize()
                }
            }
            .padding(.vertical, Theme.Space.s)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Lets the text inside grow to any Dynamic Type size by wrapping onto more lines instead of
    /// truncating or shrinking.
    func wrapsAtAnySize() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// Equal-width columns whose rows are as tall as their tallest cell. Laid out all at once: a
/// dashboard section has a handful of cells, so a lazy grid gains nothing and its estimated row
/// heights can clip wrapped text at large Dynamic Type sizes.
struct EqualColumns<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    @ViewBuilder let cell: (Item) -> Cell

    private var rows: [[Item]] {
        let width = max(columns, 1)
        return stride(from: 0, to: items.count, by: width).map { Array(items[$0..<min($0 + width, items.count)]) }
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in cell(item) }
                    // Keeps a short last row's cells the same width as the rows above.
                    ForEach(row.count..<max(columns, 1), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}
