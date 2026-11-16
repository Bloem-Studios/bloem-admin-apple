import SwiftUI

/// Lays its children out in rows that wrap, for the header's pills and actions.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

/// A titled block of the User page.
struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .bloemText(.titleMedium)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
            .bloemCard()
        }
    }
}

/// The body of a `LoadState`: loading, the server's own failure with Retry, or the loaded value.
struct LoadStateBody<Value: Sendable, Content: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            Text("Loading…").foregroundStyle(.bloemMuted)
        case .failed(let message):
            Text(message).foregroundStyle(.bloemDanger)
            Button("Try again", action: retry)
                .frame(minHeight: 44)
        case .loaded(let value):
            content(value)
        }
    }
}

struct FieldLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.bloemMuted).frame(width: 96, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A radio-style choice whose whole row selects it, at least 44 points tall. `detail` explains
/// the choice under its label.
struct ChoiceRow: View {
    let selected: Bool
    let label: String
    var detail: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                IconImage(selected ? .circleDot : .circle, size: .row)
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
