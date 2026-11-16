import SwiftUI

/// A Users list row: name, email, role and status. Tapping it opens the User page.
struct UserListRow: View {
    let user: AdminUser

    private var role: String { Vocabulary.role(user.roleLabel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(user.username).bloemText(.titleMedium)
            if !user.email.isEmpty {
                Text(user.email).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            if user.enabled {
                Text(role).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            } else {
                HStack(spacing: Theme.Space.s) {
                    Text(role).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                    StatusLabel("Disabled", tone: .warning)
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the user page")
        .accessibilityIdentifier("user-row-\(user.username)")
    }
}
