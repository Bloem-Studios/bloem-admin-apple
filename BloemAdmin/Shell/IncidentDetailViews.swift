import SwiftUI

/// Pieces shared by the detail sheets of Playback history, Logs and Audit: a labelled value that
/// wraps and can be selected, and Copy and Share for the text of the entry. Built from semantic
/// styles only, so the design layer can restyle them in one place.
struct IncidentField: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            Text(value)
                .bloemText(.bodyMedium)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A field that is left out when it has nothing to say.
struct OptionalIncidentField: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            IncidentField(label, value)
        }
    }
}

/// Copy puts the entry's text on the pasteboard; Share opens the share sheet with it.
struct IncidentShareBar: View {
    let text: String
    var copyIdentifier = "incident-copy"
    var shareIdentifier = "incident-share"
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.string = text
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", icon: copied ? .check : .copy)
            }
            .accessibilityIdentifier(copyIdentifier)
            ShareLink(item: text) {
                Label("Share", icon: .share)
            }
            .accessibilityIdentifier(shareIdentifier)
            Spacer(minLength: 0)
        }
        .buttonStyle(.bloemSecondary)
        .frame(minHeight: 44)
    }
}

/// A sheet that holds one entry's details under a Done button.
struct IncidentSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("incident-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
