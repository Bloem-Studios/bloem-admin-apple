#if DEBUG
import SwiftUI

/// UI tests start the app straight in Platform › Organizations over a stub server that lives inside the app process
/// (`--ui-testing-platform-organizations`). Nothing here is compiled into a release build, and no request leaves the
/// process: the stub answers the host `platform.example.test` itself.
///
/// The stub holds seven organizations (Riverside Club is the one the account also administers, so it offers "Open as
/// administrator"; Harbor Studio is suspended), answers five to a page so "Show more" has something to show, and keeps
/// state: a suspend, a reactivation or a plan change sticks, and a write that quotes an old revision is refused the way
/// the server refuses it.
enum PlatformOrganizationsUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-platform-organizations")
    }
}

struct PlatformOrganizationsUITestHost: View {
    @State private var router = ShellRouter()
    @State private var opened: String?
    @State private var sessionState = AdminSessionState()

    private static let server = AdminServer(id: "fixture", baseURL: URL(string: "https://platform.example.test")!, displayName: "Fixture", signInProviderID: nil)

    /// Built once per process: a view's `init` runs again whenever its parent re-evaluates, and resetting the stub
    /// there would wipe its state in the middle of a test.
    @MainActor private static var shared: (client: APIClient, session: URLSession)?

    @MainActor private static func connection() -> (client: APIClient, session: URLSession) {
        if let shared { return shared }
        PlatformOrganizationsUITestStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlatformOrganizationsUITestStub.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(baseURL: server.baseURL, accessToken: "ui-test-account", session: session)
        shared = (client, session)
        return (client, session)
    }

    var body: some View {
        let connection = Self.connection()
        NavigationStack {
            PlatformOrganizationsView(server: Self.server, client: connection.client, sessionState: sessionState, urlSession: connection.session)
                .navigationTitle("Organizations")
                .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom) {
            if let opened {
                Text("Opened \(opened) as administrator")
                    .bloemText(.bodySmall)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .accessibilityIdentifier("ui-test-opened-organization")
            }
        }
        .environment(router)
        .onAppear {
            router.organizations = [
                ScopeOrganization(serverID: Self.server.id, organizationID: PlatformOrganizationsUITestStub.riversideID, displayName: "Riverside Club"),
            ]
            router.onSelectOrganization = { organization in opened = organization.displayName }
        }
    }
}

/// An in-memory server: the platform routes the Organizations pages call, with state that changes when a write lands.
final class PlatformOrganizationsUITestStub: URLProtocol, @unchecked Sendable {
    static let riversideID = "30000000-0000-0000-0000-000000000006"
    private static let pageSize = 5

    private struct Organization {
        var id: String
        var name: String
        var slug: String
        var status: String
        var revision: Int
        var owner: Int
        var members: [[String: Any]]
        var planKey: String
        var planRevision: Int
    }

    private struct Plan {
        var key: String
        var name: String
        var revision: Int
        var screens: Int
        var downloads: Bool
    }

    private struct State {
        var organizations: [Organization] = []
        var plans: [Plan] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset() {
        func member(_ id: String, _ account: Int, _ name: String, role: String = "user", status: String = "active") -> [String: Any] {
            [
                "id": id, "organization_id": riversideID, "account_id": account, "status": status, "legacy_role": role,
                "security_revision": 3, "email": "\(name)@example.test", "username": name,
            ]
        }
        func organization(_ index: Int, _ name: String, status: String = "active", owner: Int, members: [[String: Any]] = []) -> Organization {
            Organization(
                id: String(format: "30000000-0000-0000-0000-%012d", index), name: name,
                slug: name.lowercased().replacingOccurrences(of: " ", with: "-"), status: status, revision: 7, owner: owner,
                members: members, planKey: "family", planRevision: 3
            )
        }
        var fresh = State()
        fresh.plans = [
            Plan(key: "family", name: "Family", revision: 3, screens: 2, downloads: false),
            Plan(key: "premium", name: "Premium", revision: 2, screens: 4, downloads: true),
        ]
        fresh.organizations = [
            organization(1, "Ashford Film Society", owner: 11),
            organization(2, "Brightwater Cinema", owner: 12),
            organization(3, "Cedar Hall Media", owner: 13),
            organization(4, "Harbor Studio", status: "suspended", owner: 14),
            organization(5, "Maple Street Library", owner: 15),
            organization(6, "Riverside Club", owner: 4, members: [
                member("m-avery", 4, "avery", role: "admin"), member("m-sam", 9, "sam"), member("m-jo", 10, "jo", status: "suspended"),
            ]),
            organization(7, "Willow Co-op", owner: 17),
        ]
        lock.lock()
        state = fresh
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "platform.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = self.request
        let body = Self.body(of: request)
        Self.lock.lock()
        let (status, json) = Self.route(request, body: body)
        Self.lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
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

    private static func error(_ status: Int, _ code: String, _ message: String = "Refused") -> (Int, Any) {
        (status, ["error": code, "message": message])
    }

    private static func policy(_ plan: Plan) -> [String: Any] {
        [
            "all_libraries": true, "library_ids": NSNull(), "playback_allowed": true, "max_streams": plan.screens, "max_profiles": 5,
            "transcode_allowed": true, "max_transcodes": 1, "download_allowed": plan.downloads, "download_transcode_allowed": false,
            "max_playback_quality": "1080p", "allowed_permissions": [String](), "requests_allowed": true,
        ]
    }

    private static func summary(_ organization: Organization) -> [String: Any] {
        let isRiverside = organization.id == riversideID
        return [
            "id": organization.id, "slug": organization.slug, "name": organization.name, "status": organization.status,
            "owner_account_id": organization.owner, "policy_revision": organization.revision, "is_default": false,
            "membership_count": isRiverside ? 12 : 3, "active_membership_count": isRiverside ? 10 : 3,
            "profile_count": isRiverside ? 25 : 4, "library_count": 3, "entitlement_count": 2,
        ]
    }

    private static func route(_ request: URLRequest, body: [String: Any]) -> (Int, Any) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        // Everything after "/v2/admin": the routes the pages call.
        guard let marker = path.range(of: "/v2/admin") else { return error(404, "not_found") }
        let route = String(path[marker.upperBound...])

        if method == "POST", route == "/session" {
            return (200, [
                "access_token": "ui-test-platform-pass", "expires_at": "2099-01-01T00:00:00Z",
                "context": ["key": "platform", "scope": "platform", "name": "Platform", "status": "active", "authority": "platform_admin"],
            ] as [String: Any])
        }
        if method == "GET", route == "/platform/entitlement-templates" {
            return (200, ["templates": state.plans.map { plan in
                [
                    "key": plan.key, "name": plan.name, "revision": plan.revision, "enabled": true, "archived": false, "status": "enabled",
                    "policy": policy(plan), "created_at": "2026-11-01T10:00:00Z",
                ] as [String: Any]
            }])
        }
        if method == "GET", route == "/platform/organizations/" || route == "/platform/organizations" {
            return list(query: query)
        }
        let parts = route.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "platform", parts[1] == "organizations",
              let index = state.organizations.firstIndex(where: { $0.id == parts[2] }) else { return error(404, "not_found") }
        let rest = Array(parts.dropFirst(3))
        switch (method, rest) {
        case ("GET", []):
            return (200, ["organization": summary(state.organizations[index])])
        case ("GET", ["memberships"]):
            return (200, ["memberships": state.organizations[index].members])
        case ("POST", ["suspend"]), ("POST", ["reactivate"]):
            guard body["expected_revision"] as? Int == state.organizations[index].revision else {
                return (409, ["error": "authorization_state_changed", "message": "Authorization state changed; reload and retry", "current_revision": state.organizations[index].revision])
            }
            state.organizations[index].status = rest[0] == "suspend" ? "suspended" : "active"
            state.organizations[index].revision += 1
            var changed = summary(state.organizations[index])
            for key in ["membership_count", "active_membership_count", "profile_count", "library_count", "entitlement_count"] { changed[key] = nil }
            return (200, ["organization": changed])
        case ("GET", ["entitlement"]):
            return entitlement(state.organizations[index])
        case ("POST", ["entitlement", "dry-run"]):
            return dryRun(state.organizations[index], body: body)
        case ("POST", ["entitlement", "apply"]):
            return apply(index, body: body)
        default:
            return error(404, "not_found")
        }
    }

    private static func list(query: [String: String]) -> (Int, Any) {
        let text = (query["query"] ?? "").lowercased()
        let matches = state.organizations
            .filter { text.isEmpty || $0.name.lowercased().contains(text) || $0.slug.contains(text) }
            .filter { (query["status"] ?? "").isEmpty || $0.status == query["status"] }
            .sorted { $0.name < $1.name }
        let start = Int(query["cursor"] ?? "") ?? 0
        let page = Array(matches.dropFirst(start).prefix(pageSize))
        var answer: [String: Any] = ["organizations": page.map(summary)]
        if start + pageSize < matches.count { answer["next_cursor"] = String(start + pageSize) }
        return (200, answer)
    }

    private static func entitlement(_ organization: Organization) -> (Int, Any) {
        let plan = state.plans.first { $0.key == organization.planKey }
        var answer: [String: Any] = [
            "template_key": organization.planKey, "template_revision": organization.planRevision,
            "tenant_limits": ["slots": 8, "transcodes": 2], "library_ids": NSNull(),
            "last_reconciled_at": "2026-11-12T09:30:00.123456Z",
            "audit_history_href": "platform/organizations/\(organization.id)/entitlement/audit",
        ]
        if let plan {
            answer["managed_default_group"] = ["id": 9, "name": "\(plan.name) plan", "policy": policy(plan)] as [String: Any]
        } else {
            answer["managed_default_group"] = NSNull()
        }
        return (200, answer)
    }

    private static func dryRun(_ organization: Organization, body: [String: Any]) -> (Int, Any) {
        guard let key = body["template_key"] as? String, let revision = body["template_revision"] as? Int,
              let plan = state.plans.first(where: { $0.key == key && $0.revision == revision }) else {
            return error(422, "template_unavailable", "Entitlement template revision is unavailable")
        }
        let changed = !(organization.planKey == key && organization.planRevision == revision)
        let token = "ui-token-\(key)-\(revision)"
        return (200, [
            "result": [
                "organization_id": organization.id, "template_key": key, "template_revision": revision, "group_id": 9, "dry_run": true,
                "changed": changed, "profiles_moved": 0, "previous_template_key": organization.planKey,
                "previous_template_revision": organization.planRevision, "policy": policy(plan),
            ] as [String: Any],
            "template_key": key, "template_revision": revision, "changed": changed, "dry_run_token": token, "confirmation_token": token,
            "expires_at": "2099-01-01T00:00:00Z", "changes": [Any](), "warnings": [String](),
        ] as [String: Any])
    }

    private static func apply(_ index: Int, body: [String: Any]) -> (Int, Any) {
        guard let key = body["template_key"] as? String, let revision = body["template_revision"] as? Int,
              let plan = state.plans.first(where: { $0.key == key && $0.revision == revision }),
              body["dry_run_token"] as? String == "ui-token-\(key)-\(revision)",
              !((body["idempotency_key"] as? String) ?? "").isEmpty else {
            return error(422, "validation_failed", "requires template key/revision, confirmation_token, and idempotency_key")
        }
        let previous = state.organizations[index]
        state.organizations[index].planKey = key
        state.organizations[index].planRevision = revision
        return (200, [
            "organization_id": previous.id, "template_key": key, "template_revision": revision, "group_id": 9, "dry_run": false,
            "changed": true, "profiles_moved": 3, "previous_template_key": previous.planKey,
            "previous_template_revision": previous.planRevision, "policy": policy(plan),
        ] as [String: Any])
    }
}
#endif
