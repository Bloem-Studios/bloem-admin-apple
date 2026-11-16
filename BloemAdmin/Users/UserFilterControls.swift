import SwiftUI

/// "Person" picker fed by the server's user list: choose a name, not a number. `Everyone` clears it.
struct PersonFilterPicker: View {
    @Binding var userID: String
    let options: UserPickerOptions
    var identifier = "person-filter"

    var body: some View {
        Picker("Person", selection: $userID) {
            Text("Everyone").tag("")
            // A person picked earlier stays selectable while the list is still loading.
            if !userID.isEmpty, options.userName(forID: userID) == nil {
                Text(String(localized: "User \(userID)")).tag(userID)
            }
            ForEach(options.users) { user in
                Text(user.username).tag(user.id)
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier(identifier)
    }
}

/// The Playback history filters: person, then that person's profile, then completed or partial.
struct HistoryFilterControls: View {
    @Binding var filter: HistoryFilter
    let options: UserPickerOptions
    let client: APIClient
    var identifierPrefix = "history"

    var body: some View {
        PersonFilterPicker(
            userID: Binding(
                get: { filter.userID },
                set: { newValue in
                    // A profile belongs to one person, so a new person starts with all their profiles.
                    filter = HistoryFilter(userID: newValue, completion: filter.completion)
                }
            ),
            options: options,
            identifier: identifierPrefix + "-person"
        )
        if !filter.userID.isEmpty {
            Picker("Profile", selection: Binding(
                get: { filter.profileID },
                set: { filter = HistoryFilter(userID: filter.userID, profileID: $0, completion: filter.completion) }
            )) {
                Text("All profiles").tag("")
                if !filter.profileID.isEmpty, !options.profiles.contains(where: { $0.id == filter.profileID }) {
                    Text(filter.profileID).tag(filter.profileID)
                }
                ForEach(options.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(identifierPrefix + "-profile")
        }
        Picker("Plays", selection: Binding(
            get: { filter.completion },
            set: { filter = HistoryFilter(userID: filter.userID, profileID: filter.profileID, completion: $0) }
        )) {
            ForEach(HistoryFilter.Completion.allCases) { completion in
                Text(completion.title).tag(completion)
            }
        }
        .segmentedUnlessLargeText()
        .accessibilityIdentifier(identifierPrefix + "-completion")
        .task(id: filter.userID) { await options.loadProfiles(userID: filter.userID, client: client) }
    }
}
