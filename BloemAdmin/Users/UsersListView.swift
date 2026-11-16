import SwiftUI

struct UsersListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = UsersViewModel()
    @State private var showingAddUser = false
    @State private var searchText = ""
    /// True once the first `load` call has completed — gates the initial
    /// spinner so it never re-shows on a routine 30s poll tick.
    @State private var hasLoadedOnce = false

    var body: some View {
        List(viewModel.filteredUsers(matching: searchText)) { user in
            NavigationLink {
                UserDetailView(
                    user: user,
                    admin: UserAdmin(viewModel: viewModel, client: client, sessionState: sessionState)
                )
            } label: {
                UserListRow(user: user)
            }
        }
        .searchable(text: $searchText, prompt: "Username or email")
        .overlay {
            if !hasLoadedOnce && viewModel.users.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await viewModel.load(client: client, sessionState: sessionState) } }
            } else if viewModel.filteredUsers(matching: searchText).isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    BloemEmptyState(
                        "No users",
                        icon: .users,
                        description: Text("No user accounts exist on this server")
                    )
                } else {
                    BloemEmptyState.search(text: searchText)
                }
            }
        }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddUser = true
                } label: {
                    Label("Add user", icon: .plus)
                }
            }
            .bloemFlat()
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    InvitationsListView(client: client)
                } label: {
                    Label("Invitations", icon: .mailPlus)
                }
            }
            .bloemFlat()
        }
        .sheet(isPresented: $showingAddUser) {
            AddUserView(client: client, viewModel: viewModel, sessionState: sessionState)
        }
        // Read on open and on return to the foreground; no channel carries user changes, so pull to refresh does the rest.
        .liveRefresh(client: client, channels: []) {
            await viewModel.load(client: client, sessionState: sessionState)
            hasLoadedOnce = true
        }
        .refreshable { await viewModel.load(client: client, sessionState: sessionState) }
    }
}

/// Minimal create-user form (Feature 3). Follows the same
/// success-gated-reload + visible-error pattern as every other mutating
/// action in this app: the view model's action method never self-reloads,
/// this view only calls `load()` when the action left `actionErrorMessage == nil`.
/// Deliberately internal (not `private` to this file) — `AggregateUsersView`
/// reuses this exact same sheet per server section rather than duplicating
/// the create-user form.
struct AddUserView: View {
    let client: APIClient
    let viewModel: UsersViewModel
    let sessionState: ServerScopedSession?
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role = "user"
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let roles = ["user", "admin"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Picker("Role", selection: $role) {
                        ForEach(roles, id: \.self) { Text(Vocabulary.role($0)).tag($0) }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.bloemDanger)
                }
            }
            .navigationTitle("Add user")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(isSaving || username.isEmpty || email.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        // Branch on createUser's own return value, not viewModel.actionErrorMessage
        // — see UsersViewModel.createUser's doc comment for why a shared
        // property alone isn't a safe success/failure signal for this sheet.
        let succeeded = await viewModel.createUser(username: username, email: email, password: password, role: role, client: client, sessionState: sessionState)
        guard succeeded else {
            errorMessage = viewModel.actionErrorMessage ?? String(localized: "The user couldn't be created. Try again.")
            return
        }
        await viewModel.load(client: client, sessionState: sessionState)
        dismiss()
    }
}
