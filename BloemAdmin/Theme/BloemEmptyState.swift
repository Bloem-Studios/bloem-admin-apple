import SwiftUI

/// An empty or failed page, said the Bloem way: what is missing (or what went wrong), one line on how to fix
/// it, and the one action that does. It takes the shapes of `ContentUnavailableView`, which it replaces
/// because that view sets its text in the system font and draws SF Symbols.
///
/// Titles name the state in sentence case without a final period; an error never apologizes.
struct BloemEmptyState<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.s) {
                label
                    .labelStyle(EmptyStateLabelStyle())
                description
                    .bloemText(.bodyMedium)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            actions
                .bloemText(.titleMedium)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Without actions the state reads as one element, its title then its description (as the system's own
        // empty view did); with actions the buttons stay separate so VoiceOver can reach them.
        .accessibilityElement(children: Actions.self == EmptyView.self ? .combine : .contain)
    }
}

/// The icon above the title, both in the text colours: a 20 icon in muted, the title in titleMedium.
private struct EmptyStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Theme.Space.s) {
            configuration.icon
                .foregroundStyle(Theme.muted)
            configuration.title
                .bloemText(.titleMedium)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
        }
    }
}

extension BloemEmptyState where Description == EmptyView, Actions == EmptyView {
    init(@ViewBuilder label: () -> Label) {
        self.init(label: label, description: { EmptyView() }, actions: { EmptyView() })
    }
}

extension BloemEmptyState where Actions == EmptyView {
    init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension BloemEmptyState where Description == EmptyView {
    init(@ViewBuilder label: () -> Label, @ViewBuilder actions: () -> Actions) {
        self.init(label: label, description: { EmptyView() }, actions: actions)
    }
}

extension BloemEmptyState where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView {
    init(_ title: LocalizedStringKey, icon: BloemIcon, description: Text) {
        self.init(
            label: { SwiftUI.Label(title, icon: icon) },
            description: { description },
            actions: { EmptyView() }
        )
    }

    init<S: StringProtocol>(_ title: S, icon: BloemIcon, description: Text) {
        self.init(
            label: { SwiftUI.Label(title, icon: icon) },
            description: { description },
            actions: { EmptyView() }
        )
    }
}

extension BloemEmptyState where Label == SwiftUI.Label<Text, Image>, Description == EmptyView, Actions == EmptyView {
    init(_ title: LocalizedStringKey, icon: BloemIcon) {
        self.init(label: { SwiftUI.Label(title, icon: icon) })
    }
}

extension BloemEmptyState where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView {
    /// Nothing matches what was typed in a search field.
    static func search(text: String) -> BloemEmptyState {
        BloemEmptyState(
            String(localized: "No results for “\(text)”"),
            icon: .search,
            description: Text("Check the spelling or try a different search")
        )
    }
}
