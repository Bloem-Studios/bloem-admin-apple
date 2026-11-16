import SwiftUI

/// The web's page search as a full-screen sheet: a text field over every page the current context offers,
/// matched on label, description and keywords. Picking a page calls `onPick`; the arrow calls `onDismiss`.
struct PageSearchSheet: View {
    let destinations: [AdminDestination]
    let selectedID: String?
    let onPick: (AdminDestination) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.shellInteractionLock) private var lock

    private var pages: [SearchablePage] { destinations.map(SearchablePage.init) }

    var body: some View {
        let locked = lock?.isLocked ?? false
        let groups = PageSearch.filter(pages, query: query)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onDismiss) {
                    IconImage(.chevronLeft, size: .bar)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(String(localized: "Close search"))
                .accessibilityIdentifier(ShellID.searchClose)

                IconImage(.search, size: .row)
                    .foregroundStyle(.bloemMuted)
                    .accessibilityHidden(true)
                TextField(String(localized: "Search"), text: $query)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .frame(minHeight: 44)
                    .onSubmit {
                        // Return opens the first match, as the web's palette does.
                        if !locked, let first = groups.first?.pages.first { onPick(first.destination) }
                    }
                    .accessibilityIdentifier(ShellID.searchField)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        IconImage(.circleX, size: .inline)
                            .foregroundStyle(.bloemMuted)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.horizontal, 8)
            .background(Theme.surface)

            if groups.isEmpty {
                Text("No matching pages")
                    .foregroundStyle(.bloemMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
                    .accessibilityIdentifier(ShellID.searchEmpty)
            } else {
                List {
                    ForEach(groups) { section in
                        Section {
                            ForEach(section.pages) { page in
                                SearchResultRow(page: page, current: page.id == selectedID) {
                                    onPick(page.destination)
                                }
                                .disabled(locked)
                                .accessibilityIdentifier(ShellID.searchResultPrefix + page.id)
                            }
                        } header: {
                            Text(section.group.label)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(ShellID.searchGroupPrefix + String(describing: section.group))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .bloemPageBackground()
                .accessibilityLabel(String(localized: "Pages"))
            }

        }
        .background(Theme.background)
        .task { fieldFocused = true }
    }
}

private struct SearchResultRow: View {
    let page: SearchablePage
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconImage(page.destination.icon, size: .row)
                    .foregroundStyle(.bloemMuted)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.label)
                        .bloemText(.titleMedium)
                    if !page.description.isEmpty {
                        Text(page.description)
                            .bloemText(.bodySmall)
                            .foregroundStyle(.bloemMuted)
                    }
                }
                Spacer(minLength: 0)
                if current {
                    IconImage(.check, size: .row)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
