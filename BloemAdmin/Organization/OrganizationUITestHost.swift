#if DEBUG
import SwiftUI

/// UI tests start the app straight in the organization pages, over a stub server that lives inside the app process
/// (`--ui-testing-organization`, `=suspended`, `=nested`, `=support` or `=support-access`). Nothing here is compiled
/// into a release build, and no request leaves the process: the stub answers the host `fixture.example.test` itself.
enum OrganizationUITestScenario: Equatable {
    /// A server that predates organization support: no support routes.
    case admin
    /// The server answers the pass exchange with `403 organization_suspended`.
    case suspended
    /// The organization is mounted the way the app mounts it: pushed from a list inside a NavigationStack, under a
    /// container that checks access again every time it appears (as `AdminGateView` does).
    case nested
    /// A server with organization support: reset links, sign-outs, profile edits and the organization's streams.
    case support
    /// As `support`, with the pass opened under the server Owner's break-glass support access.
    case supportAccess

    static var current: OrganizationUITestScenario? {
        for argument in ProcessInfo.processInfo.arguments {
            if argument == "--ui-testing-organization" { return .admin }
            if argument == "--ui-testing-organization=suspended" { return .suspended }
            if argument == "--ui-testing-organization=nested" { return .nested }
            if argument == "--ui-testing-organization=support" { return .support }
            if argument == "--ui-testing-organization=support-access" { return .supportAccess }
        }
        return nil
    }
}

struct OrganizationUITestHost: View {
    let scenario: OrganizationUITestScenario
    @State private var choosing = false

    /// Built once per process. A SwiftUI view's `init` runs again whenever its parent re-evaluates (a lock or scene
    /// change), so resetting the stub there would wipe its state in the middle of a test.
    @MainActor private static var shared: OrganizationSession?

    @MainActor private static func session(for scenario: OrganizationUITestScenario) -> OrganizationSession {
        if let shared { return shared }
        OrganizationUITestStub.reset(
            suspended: scenario == .suspended,
            support: scenario == .support || scenario == .supportAccess,
            supportAccess: scenario == .supportAccess
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrganizationUITestStub.self]
        let urlSession = URLSession(configuration: configuration)
        let baseURL = URL(string: "https://fixture.example.test")!
        let account = APIClient(baseURL: baseURL, accessToken: "ui-test-account", session: urlSession)
        let created = OrganizationSession(
            account: account, baseURL: baseURL, organizationID: OrganizationUITestStub.organizationID, session: urlSession
        )
        shared = created
        return created
    }

    private var session: OrganizationSession { Self.session(for: scenario) }

    var body: some View {
        if scenario == .nested {
            NavigationStack {
                List {
                    NavigationLink("Example") {
                        OrganizationUITestGateMimic { organization }
                    }
                }
                .navigationTitle("Servers")
            }
        } else {
            organization
        }
    }

    @ViewBuilder
    private var organization: some View {
        if choosing {
            VStack(spacing: 12) {
                Text("Choose an organization").bloemText(.titleMedium)
                Button("Back to the organization") { choosing = false }
            }
            .accessibilityIdentifier("organization-context-choice")
        } else {
            OrganizationAdminRootView(
                session: session, accountSession: nil, title: "Acme Media",
                onChooseContext: { choosing = true },
                usesEnclosingNavigationStack: scenario == .nested
            )
        }
    }
}

/// Behaves like `AdminGateView` for the nested scenario: it shows a progress view while it checks access, then the
/// organization, and counts its checks and appearances so a test can tell whether a page covered it.
private struct OrganizationUITestGateMimic<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var checks = 0
    @State private var appearances = 0
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            if ready { content() } else { ProgressView("Checking access…").frame(maxHeight: .infinity) }
            Text("Gate checks: \(checks), appearances: \(appearances)")
                .bloemText(.labelSmall)
                .accessibilityIdentifier("ui-test-gate-checks")
        }
        .onAppear { appearances += 1 }
        .task {
            // The same rule as `AdminGateViewModel.shouldCheckAccessOnAppear`: an admitted organization is kept when a
            // page that covered the gate goes away.
            guard !ready else { return }
            checks += 1
            try? await Task.sleep(for: .milliseconds(200))
            ready = true
        }
    }
}

/// An in-memory server: just enough of the organization routes, with state that changes when a write lands.
final class OrganizationUITestStub: URLProtocol, @unchecked Sendable {
    static let organizationID = "10000000-0000-0000-0000-000000000001"
    static let membershipID = "20000000-0000-0000-0000-000000000001"

    private struct Profile { var id: String; var name: String; var groupID: Int }
    private struct Person {
        var accountID: Int; var name: String; var email: String; var status: String; var revision: Int
        var membershipID: String; var profiles: [Profile]
    }
    private struct Group { var id: Int; var name: String; var isDefault: Bool }
    private struct Library { var id: Int; var name: String; var owned: Bool; var status: String; var revision: Int }
    private struct Invitation { var id: String; var email: String }
    private struct Stream { var id: String; var person: String; var title: String }
    private struct State {
        var suspended = false
        var people: [Person] = []
        var groups: [Group] = []
        var libraries: [Library] = []
        var invitations: [Invitation] = []
        var selectionQuery = ""
        /// The organization support routes answer (organization_support_v1).
        var support = false
        /// The pass is opened under break-glass support access; `supportClosed` once it is ended.
        var supportAccess = false
        var supportClosed = false
        var sessionIDs: [Int: [String]] = [:]
        var streams: [Stream] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    private static let supportAccessID = "40000000-0000-0000-0000-000000000001"

    static func reset(suspended: Bool, support: Bool = false, supportAccess: Bool = false) {
        let names = ["Alex Adams", "Blake Baker", "Casey Chen", "Dana Diaz", "Eli Evans", "Fran Foster",
                     "Gray Green", "Harper Hill", "Indy Ito", "Jules Jones", "Kim Kerr", "Lee Lopez"]
        var fresh = State()
        fresh.suspended = suspended
        fresh.people = names.enumerated().map { index, name in
            let account = 101 + index
            return Person(
                accountID: account, name: name, email: "\(name.split(separator: " ")[0].lowercased())@example.test",
                status: "active", revision: 4, membershipID: account == 101 ? membershipID : "person-membership-\(account)",
                profiles: [Profile(id: "p\(account)", name: "Living room", groupID: index % 4 == 3 ? 4 : 3)]
            )
        }
        fresh.groups = [Group(id: 3, name: "Family", isDefault: true), Group(id: 4, name: "Kids", isDefault: false)]
        fresh.libraries = [
            Library(id: 1, name: "Films", owned: true, status: "", revision: 0),
            Library(id: 2, name: "Shows", owned: false, status: "active", revision: 9),
        ]
        fresh.support = support
        fresh.supportAccess = supportAccess
        if support {
            fresh.sessionIDs = Dictionary(uniqueKeysWithValues: fresh.people.map { ($0.accountID, ["s\($0.accountID)-a", "s\($0.accountID)-b"]) })
            fresh.streams = [Stream(id: "st1", person: "Blake Baker", title: "The Long Walk")]
        }
        lock.lock()
        state = fresh
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = self.request
        let body = Self.body(of: request)
        Self.lock.lock()
        let (status, json) = Self.route(request, body: body)
        Self.lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 204 { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }

    private static func error(_ status: Int, _ code: String) -> (Int, Any) {
        (status, ["error": code, "message": code == "organization_suspended" ? "Tenant access is suspended" : "Refused"])
    }

    private static func personJSON(_ person: Person) -> [String: Any] {
        [
            "organization_id": organizationID, "account_id": person.accountID, "email": person.email,
            "display_name": person.name, "membership_id": person.membershipID, "membership_status": person.status,
            "legacy_role": person.accountID == 101 ? "admin" : "user", "security_revision": person.revision,
            "last_activity": "2026-11-12T09:30:00.000Z",
            "profiles": person.profiles.map { profile in
                var row: [String: Any] = [
                    "id": profile.id, "name": profile.name, "group_id": profile.groupID,
                    "group_name": state.groups.first { $0.id == profile.groupID }?.name ?? "",
                    "updated_at": "2026-11-12T08:00:00.000Z",
                ]
                if state.support {
                    row["revision"] = 2
                    row["has_pin"] = true
                    row["is_primary"] = true
                }
                return row
            },
        ]
    }

    /// The organization support routes, when the scenario serves them; nil for anything else.
    private static func supportRoute(_ method: String, _ route: String, body: [String: Any]) -> (Int, Any)? {
        if route == "/support-capabilities" {
            guard state.support else { return error(404, "not_found") }
            return (200, [
                "password_reset": ["email": true, "link": true], "sessions": true, "devices": true,
                "profiles": ["add": true, "rename": true, "clear_pin": true, "remove": true],
                "streams": ["list": true, "stop": true, "message": true],
            ] as [String: Any])
        }
        guard state.support else { return nil }
        let parts = route.split(separator: "/").map(String.init)
        switch (method, parts.first ?? "") {
        case ("DELETE", "support-access") where state.supportAccess:
            state.supportClosed = true
            return (204, [String: Any]())
        case ("GET", "streams"):
            return (200, ["streams": state.streams.map { stream in
                [
                    "session_id": stream.id, "account_id": 102, "person_name": stream.person, "profile_id": "p102",
                    "profile_name": "Living room", "title": stream.title, "media_type": "movie",
                    "started_at": "2026-11-13T11:00:00Z", "updated_at": "2026-11-13T11:20:00Z", "position_seconds": 1310.5,
                    "duration_seconds": 5400, "is_paused": false, "play_method": "transcode", "video_decision": "transcode",
                    "audio_decision": "direct",
                    "device": ["name": "Living room TV", "platform": "androidtv", "id": "dev-1", "app": "Bloem 1.4.2"] as [String: Any],
                    "can_stop": true, "can_message": true,
                ] as [String: Any]
            }])
        case ("POST", "streams") where parts.count == 3 && parts[2] == "stop":
            state.streams.removeAll { $0.id == parts[1] }
            return (200, ["session_id": parts[1], "authority_revoked": true, "already_revoked": false, "client_notified": true] as [String: Any])
        case ("POST", "streams") where parts.count == 3 && parts[2] == "message":
            return (202, ["command_id": body["command_id"] as? String ?? "", "sequence": body["sequence"] as? Int ?? 1, "outcome": "applied", "delivery": "dispatched"] as [String: Any])
        default:
            break
        }
        guard parts.count >= 3, parts[0] == "people", let account = Int(parts[1]),
              let index = state.people.firstIndex(where: { $0.accountID == account }) else { return nil }
        let person = state.people[index]
        switch (method, parts[2], parts.count) {
        case ("POST", "password-reset", 3):
            let link = body["delivery"] as? String == "link"
            var reset: [String: Any] = [
                "delivery": link ? "link" : "email", "delivery_status": link ? "not_requested" : "sent",
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(link ? 4 * 3600 : 24 * 3600)),
            ]
            if link { reset["reset_url"] = "https://fixture.example.test/reset-password/ui-test-reset-token" }
            return (201, ["reset": reset, "person": personJSON(person)] as [String: Any])
        case ("GET", "sessions", 3):
            return (200, ["sessions": (state.sessionIDs[account] ?? []).enumerated().map { offset, id in
                [
                    "id": id, "device_name": offset == 0 ? "Living room TV" : "Phone", "device_id": "dev-\(offset)",
                    "device_platform": offset == 0 ? "androidtv" : "ios", "auth_method": "password", "profile_id": NSNull(),
                    "profile_name": NSNull(), "created_at": "2026-11-12T08:00:00Z", "last_seen_at": "2026-11-13T11:00:00Z",
                    "expires_at": "2026-12-12T08:00:00Z",
                ] as [String: Any]
            }])
        case ("DELETE", "sessions", 3):
            let ended = state.sessionIDs[account]?.count ?? 0
            state.sessionIDs[account] = []
            state.people[index].revision += 1
            return (200, ["person": personJSON(state.people[index]), "revoked": ["sessions": ended]] as [String: Any])
        case ("DELETE", "sessions", 4):
            state.sessionIDs[account]?.removeAll { $0 == parts[3] }
            return (204, [String: Any]())
        case ("GET", "devices", 3):
            return (200, ["devices": [[
                "device_id": "dev-0", "name": "Living room TV", "platform": "androidtv", "last_seen_at": "2026-11-13T11:00:00Z",
                "profiles": [["profile_id": "p\(account)", "profile_name": "Living room"]],
            ] as [String: Any]]])
        case ("DELETE", "devices", 4):
            return (204, [String: Any]())
        default:
            return nil
        }
    }

    private static func groupJSON(_ group: Group) -> [String: Any] {
        [
            "id": String(group.id), "name": group.name, "description": "", "library_ids": NSNull(),
            "max_playback_quality": "", "download_allowed": true, "download_transcode_allowed": false,
            "transcode_allowed": true, "audio_transcode_allowed": true, "max_streams": 2, "max_transcodes": 1,
            "max_remote_stream_bitrate_kbps": 0, "max_local_stream_bitrate_kbps": 0, "max_profiles": 5,
            "allowed_permissions": NSNull(), "requests_allowed": true, "is_default": group.isDefault,
            "member_count": state.people.filter { $0.profiles.contains { $0.groupID == group.id } }.count,
            "created_at": "2026-10-01T00:00:00.000Z", "updated_at": "2026-10-02T00:00:00.000Z",
        ]
    }

    private static func matching(_ query: String) -> [Person] {
        let needle = query.lowercased()
        return state.people.filter { needle.isEmpty || $0.name.lowercased().contains(needle) || $0.email.lowercased().contains(needle) }
    }

    private static func route(_ request: URLRequest, body: [String: Any]) -> (Int, Any) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }

        if path.hasSuffix("/admin/session") {
            if state.suspended { return error(403, "organization_suspended") }
            let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(14 * 60))
            if state.supportAccess {
                // The Owner's break-glass access: no membership, three hours left; once closed, a renewal is 404.
                if state.supportClosed { return error(404, "not_found") }
                return (200, [
                    "access_token": "ui-test-support-pass", "expires_at": expires,
                    "context": [
                        "key": "organization:\(organizationID)", "scope": "organization", "organization_id": organizationID,
                        "name": "Acme Media", "status": "active", "authority": "platform_admin", "policy_revision": 7,
                        "access_basis": "support", "support_access_id": supportAccessID,
                        "support_expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600)),
                    ] as [String: Any],
                ] as [String: Any])
            }
            return (200, [
                "access_token": "ui-test-pass", "expires_at": expires,
                "context": [
                    "key": "organization:\(organizationID)", "scope": "organization", "organization_id": organizationID,
                    "membership_id": membershipID, "name": "Acme Media", "status": "active", "authority": "organization_admin",
                    "policy_revision": 7, "security_revision": 11,
                ] as [String: Any],
            ] as [String: Any])
        }
        // The organization routes all sit under `.../admin/organization`; the stub only needs what follows it.
        guard let anchor = path.range(of: "/admin/organization") else { return error(404, "not_found") }
        let route = String(path[anchor.upperBound...])
        if let answer = supportRoute(method, route, body: body) { return answer }

        switch (method, route) {
        case ("GET", "/overview"):
            return (200, ["organization": [
                "id": organizationID, "slug": "acme", "name": "Acme Media", "status": "active", "owner_account_id": 101,
                "policy_revision": 7, "is_default": false, "membership_count": state.people.count,
                "active_membership_count": state.people.filter { $0.status == "active" }.count,
                "profile_count": state.people.count, "library_count": 1, "entitlement_count": 1,
            ] as [String: Any]])
        case ("GET", "/people"):
            var people = matching(query("query"))
            let statuses = query("status").split(separator: ",").map(String.init)
            if !statuses.isEmpty { people = people.filter { statuses.contains($0.status) } }
            if let group = Int(query("group_id")) { people = people.filter { $0.profiles.contains { $0.groupID == group } } }
            return (200, ["items": people.map(personJSON), "approximate_total": people.count] as [String: Any])
        case ("GET", "/groups"):
            return (200, ["groups": state.groups.map(groupJSON)])
        case ("POST", "/groups"):
            let id = (state.groups.map(\.id).max() ?? 0) + 1
            let group = Group(id: id, name: body["name"] as? String ?? "New group", isDefault: false)
            state.groups.append(group)
            return (201, ["group": groupJSON(group), "policy_revision": 7] as [String: Any])
        case ("GET", "/libraries"):
            return (200, ["libraries": state.libraries.map { library in
                var row: [String: Any] = ["folder_id": library.id, "name": library.name, "type": "movie", "access_kind": library.owned ? "owned" : "entitled"]
                if !library.owned {
                    row["entitlement"] = [
                        "id": "30000000-0000-0000-0000-000000000001", "organization_id": organizationID,
                        "status": library.status, "security_revision": library.revision,
                    ] as [String: Any]
                }
                return row
            }])
        case ("GET", "/invitations"):
            return (200, ["invitations": state.invitations.map { invitation in
                [
                    "id": invitation.id, "email": invitation.email, "delivery": "link", "role": "user", "library_ids": NSNull(),
                    "create_profile": true, "show_tour": true, "note": "", "invited_by": "101", "invited_by_name": "Alex Adams",
                    "status": "pending", "expires_at": "2026-11-20T00:00:00.000Z", "created_at": "2026-11-13T00:00:00.000Z",
                ] as [String: Any]
            }])
        case ("POST", "/invitations"):
            let invitation = Invitation(id: "inv-\(state.invitations.count + 1)", email: body["email"] as? String ?? "")
            state.invitations.insert(invitation, at: 0)
            return (201, [
                "invitation": [
                    "id": invitation.id, "email": invitation.email, "delivery": "link", "role": "user", "library_ids": NSNull(),
                    "create_profile": true, "show_tour": true, "note": "", "invited_by": "101", "invited_by_name": "Alex Adams",
                    "status": "pending", "expires_at": "2026-11-20T00:00:00.000Z", "created_at": "2026-11-13T00:00:00.000Z",
                ] as [String: Any],
                "claim_token": "ui-test-claim-token",
            ] as [String: Any])
        case ("GET", "/activity"):
            return (200, ["events": [[
                "id": 1, "source": "people", "created_at": "2026-11-12T09:30:00.000Z", "actor_account_id": 101,
                "action": "people.membership_updated", "target_id": "person-membership-102", "outcome": "success",
            ] as [String: Any]]])
        case ("GET", "/entitlement-cohorts"):
            return (200, ["cohorts": [[
                "cohort_id": "c1", "organization_id": organizationID, "name": "Family plan", "revision": 2, "access_group_id": 3,
                "source_template_key": "family", "source_template_revision": 1, "derivation_kind": "exact_template",
                "policy": ["library_ids": NSNull(), "playback_allowed": true, "max_streams": 2, "max_profiles": 5,
                           "transcode_allowed": true, "max_transcodes": 1, "download_allowed": false, "download_transcode_allowed": false,
                           "max_playback_quality": "original", "allowed_permissions": NSNull(), "requests_allowed": true] as [String: Any],
                "policy_digest": "d", "archived": false, "member_count": 6, "created_by_account_id": 101,
                "created_at": "2026-10-01T00:00:00.000Z",
            ] as [String: Any]]])
        case ("GET", "/policy-decisions"):
            return (200, ["decisions": [[
                "id": 1, "timestamp": "2026-11-12T09:30:00.000Z", "subject": ["account_id": 102, "profile_id": "p102"] as [String: Any],
                "group": ["id": 3, "name": "Family"] as [String: Any], "action": "library_access_check",
                "resource": ["library_id": 1] as [String: Any], "allowed": false, "reason_code": "item_outside_user_libraries",
            ] as [String: Any]]])
        case ("GET", "/policy-decisions/1"):
            return (200, ["decision": [
                "id": 1, "timestamp": "2026-11-12T09:30:00.000Z", "organization": ["id": organizationID] as [String: Any],
                "subject": ["account_id": 102, "profile_id": "p102"] as [String: Any], "group": ["id": 3, "name": "Family"] as [String: Any],
                "library_ceiling": [1], "action": "library_access_check",
                "resource": ["library_id": 1, "token": "[redacted]"] as [String: Any], "allowed": false,
                "reason_code": "item_outside_user_libraries", "policy_versions": [["kind": "group", "version": 2] as [String: Any]],
            ] as [String: Any]])
        case ("POST", "/people/selections"):
            state.selectionQuery = body["query"] as? String ?? ""
            return (201, ["selection": [
                "token": "ui-test-selection", "matched": matching(state.selectionQuery).count, "excluded": 0,
                "expires_at": "2026-11-13T12:30:00.000Z",
            ] as [String: Any]])
        case ("POST", "/people/bulk-jobs"):
            let kind = body["kind"] as? String ?? ""
            var succeeded = 0
            var skipped: [[String: Any]] = []
            let targets = Set(matching(state.selectionQuery).map(\.accountID))
            for index in state.people.indices where targets.contains(state.people[index].accountID) {
                let person = state.people[index]
                if kind == BulkKind.suspend {
                    if person.membershipID == membershipID {
                        skipped.append(["account_id": person.accountID, "reason": "actor_authority_target"])
                    } else {
                        state.people[index].status = "suspended"
                        succeeded += 1
                    }
                } else if kind == BulkKind.reactivate {
                    state.people[index].status = "active"
                    succeeded += 1
                } else if let group = body["group_id"] as? Int {
                    state.people[index].profiles = person.profiles.map { Profile(id: $0.id, name: $0.name, groupID: group) }
                    succeeded += 1
                }
            }
            return (201, ["job": [
                "job_id": "job-1", "status": "completed", "progress_current": targets.count, "progress_total": targets.count,
                "succeeded": succeeded, "skipped": skipped, "failed": [] as [[String: Any]],
            ] as [String: Any]])
        default:
            break
        }

        let parts = route.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "people", let account = Int(parts[1]), let index = state.people.firstIndex(where: { $0.accountID == account }) {
            if method == "GET", parts.count == 2 { return (200, ["person": personJSON(state.people[index])]) }
            if method == "PATCH", parts.count == 4, parts[2] == "memberships" {
                state.people[index].status = body["status"] as? String ?? state.people[index].status
                state.people[index].revision += 1
                return (200, ["person": personJSON(state.people[index])])
            }
            if method == "PATCH", parts.count == 4, parts[2] == "profiles", let group = body["group_id"] as? Int {
                state.people[index].profiles = state.people[index].profiles.map {
                    $0.id == parts[3] ? Profile(id: $0.id, name: $0.name, groupID: group) : $0
                }
                state.people[index].revision += 1
                return (200, ["person": personJSON(state.people[index])])
            }
        }
        if parts.count == 2, parts[0] == "entitlements", method == "PUT", let id = Int(parts[1]), let index = state.libraries.firstIndex(where: { $0.id == id }) {
            state.libraries[index].status = body["status"] as? String ?? state.libraries[index].status
            state.libraries[index].revision += 1
            return (200, ["entitlement": [
                "id": "30000000-0000-0000-0000-000000000001", "organization_id": organizationID,
                "status": state.libraries[index].status, "security_revision": state.libraries[index].revision,
            ] as [String: Any]])
        }
        return error(404, "not_found")
    }
}
#endif
