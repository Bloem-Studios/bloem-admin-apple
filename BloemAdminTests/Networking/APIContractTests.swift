import XCTest
@testable import BloemAdmin

/// Calls every function of `Networking/API/*.swift` and `Networking/AuthAPI.swift` once through the
/// URL protocol stub and checks each request against `Resources/api-contract.json`, which
/// `scripts/extract-api-contract.py` generates from the server's OpenAPI documents: the operation
/// exists, every query parameter is declared for it, every required query parameter is sent, every
/// numeric query value is within the declared minimum and maximum, and a required body is present
/// as non-empty JSON. The server rejects undeclared query parameters and missing bodies, so a
/// request that fails here fails on a real server.
@MainActor
final class APIContractTests: XCTestCase {
    private struct Case {
        let function: String
        /// "METHOD /template" as in the contract, or "EXEMPT METHOD /path" for a route outside it.
        let operation: String
        let call: @MainActor @Sendable (APIClient) async throws -> Void
    }

    private final class BundleToken {}

    private func loadContract() throws -> [String: [String: [String: Any]]] {
        let url = try XCTUnwrap(
            Bundle(for: BundleToken.self).url(forResource: "api-contract", withExtension: "json"),
            "api-contract.json is missing from the test bundle; run scripts/extract-api-contract.py"
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: [String: [String: Any]]])
    }

    private static let baseURL = URL(string: "https://example.test")!
    private static let identity = PlaybackCommandIdentity(commandID: "c1", sequence: 1)

    private static let cases: [Case] = [
        Case(function: "playbackHistory", operation: "GET /api/v2/admin/playback-history") { _ = try await $0.playbackHistory(filter: HistoryFilter(userID: "u1"), cursor: "c1") },
        Case(function: "playbackHistory", operation: "GET /api/v2/admin/playback-history") { _ = try await $0.playbackHistory(filter: HistoryFilter(), cursor: nil) },

        Case(function: "listInvitations", operation: "GET /api/v2/admin/invitations") { _ = try await $0.listInvitations() },
        Case(function: "createInvitation", operation: "POST /api/v2/admin/invitations") { _ = try await $0.createInvitation(CreateInvitationRequest(email: "a@example.test", role: "user", note: "n")) },
        Case(function: "resendInvitation", operation: "POST /api/v2/admin/invitations/{id}/resend") { _ = try await $0.resendInvitation(id: "i1") },
        Case(function: "revokeInvitation", operation: "DELETE /api/v2/admin/invitations/{id}") { try await $0.revokeInvitation(id: "i1") },

        Case(function: "mediaRequests", operation: "GET /api/v2/admin/requests") { _ = try await $0.mediaRequests() },
        Case(function: "requestQueuePage", operation: "GET /api/v2/admin/requests") {
            _ = try await $0.requestQueuePage(view: .needsApproval, search: "dune", mediaType: "movie", requestedBy: "7", cursor: "c1")
        },
        Case(function: "requestCounts", operation: "GET /api/v2/admin/requests/counts") { _ = try await $0.requestCounts() },
        Case(function: "requestEvents", operation: "GET /api/v2/admin/requests/{id}/events") { _ = try await $0.requestEvents(id: "r1") },
        Case(function: "actOnRequest", operation: "POST /api/v2/admin/requests/{id}/approve") { try await $0.actOnRequest(id: "r1", action: .approve) },
        Case(function: "actOnRequest", operation: "POST /api/v2/admin/requests/{id}/decline") { try await $0.actOnRequest(id: "r1", action: .decline, reason: "no") },
        Case(function: "actOnRequest", operation: "POST /api/v2/admin/requests/{id}/retry") { try await $0.actOnRequest(id: "r1", action: .retry) },
        Case(function: "actOnRequest", operation: "POST /api/v2/admin/requests/{id}/cancel") { try await $0.actOnRequest(id: "r1", action: .cancel) },

        Case(function: "listSessions", operation: "GET /api/v2/admin/sessions") { _ = try await $0.listSessions() },
        Case(function: "createEventsSocketTicket", operation: "POST /api/v2/events/ws-ticket") { _ = try await $0.createEventsSocketTicket() },
        Case(function: "sendPlaybackCommand", operation: "POST /api/v2/admin/sessions/{session_id}/pause") { try await $0.sendPlaybackCommand(sessionID: "s1", action: .pause, identity: identity) },
        Case(function: "sendPlaybackCommand", operation: "POST /api/v2/admin/sessions/{session_id}/resume") { try await $0.sendPlaybackCommand(sessionID: "s1", action: .resume, identity: identity) },
        Case(function: "sendPlaybackCommand", operation: "POST /api/v2/admin/sessions/{session_id}/stop") { try await $0.sendPlaybackCommand(sessionID: "s1", action: .stop, identity: identity) },
        Case(function: "sendSessionMessage", operation: "POST /api/v2/admin/sessions/{session_id}/message") { _ = try await $0.sendSessionMessage(sessionID: "s1", title: "t", message: "m", identity: identity) },
        Case(function: "terminateSession", operation: "POST /api/v2/admin/sessions/{session_id}/terminate") { try await $0.terminateSession(sessionID: "s1") },
        Case(function: "terminateSession", operation: "POST /api/v2/admin/sessions/{session_id}/terminate") { try await $0.terminateSession(sessionID: "s1", reason: "r") },

        Case(function: "auditLogs", operation: "GET /api/v2/admin/logs/audit") { _ = try await $0.auditLogs(filter: AuditFilter(userID: "u1"), cursor: "c1", limit: AuditViewModel.pageSize) },
        Case(function: "operationalLogs", operation: "GET /api/v2/admin/logs/app") { _ = try await $0.operationalLogs(filter: LogFilter(level: "info", q: "scan"), cursor: "c1", limit: LogsViewModel.pageSize) },

        Case(function: "tasks", operation: "GET /api/v2/admin/tasks") { _ = try await $0.tasks() },
        Case(function: "runTask", operation: "POST /api/v2/admin/tasks/{key}/run") { try await $0.runTask(key: "k") },
        Case(function: "cancelTask", operation: "POST /api/v2/admin/tasks/{key}/cancel") { try await $0.cancelTask(key: "k") },
        Case(function: "taskSchedule", operation: "GET /api/v2/admin/tasks/{key}/triggers") { _ = try await $0.taskSchedule(key: "k") },
        Case(function: "updateTaskSchedule", operation: "PUT /api/v2/admin/tasks/{key}/triggers") { try await $0.updateTaskSchedule(key: "k", triggers: [TaskTrigger(type: "startup")], validator: "\"v1\"") },

        Case(function: "listAdminLibraries", operation: "GET /api/v2/libraries") { _ = try await $0.listAdminLibraries() },
        Case(function: "scanControlsAvailable", operation: "GET /api/v2/scan/capabilities") { _ = try await $0.scanControlsAvailable() },
        Case(function: "scanRuns", operation: "GET /api/v2/admin/autoscan/scans") { _ = try await $0.scanRuns(status: "running", limit: APIClient.activeScanLimit) },
        Case(function: "scanRuns", operation: "GET /api/v2/admin/autoscan/scans") { _ = try await $0.scanRuns(status: nil, limit: APIClient.recentScanLimit) },
        Case(function: "startScan", operation: "POST /api/v2/scan") { try await $0.startScan(libraryID: "3") },
        Case(function: "stopScans", operation: "POST /api/v2/scan/cancel") { _ = try await $0.stopScans(libraryID: "3") },
        Case(function: "checkMount", operation: "POST /api/v2/libraries/{id}/check-mount") { _ = try await $0.checkMount(libraryID: "3") },
        Case(function: "refreshLibraryMetadata", operation: "POST /api/v2/libraries/{id}/refresh-metadata") { _ = try await $0.refreshLibraryMetadata(libraryID: "3", mode: .missingOnly) },
        Case(function: "refreshLibraryMetadata", operation: "POST /api/v2/libraries/{id}/refresh-metadata") { _ = try await $0.refreshLibraryMetadata(libraryID: "3", mode: .all) },
        Case(function: "libraryRefreshJobs", operation: "GET /api/v2/admin/jobs") { _ = try await $0.libraryRefreshJobs() },
        Case(function: "cancelAdminJob", operation: "POST /api/v2/admin/jobs/{id}/cancel") { try await $0.cancelAdminJob(id: "j1") },
        Case(function: "taskHistory", operation: "GET /api/v2/admin/tasks/{key}/history") { _ = try await $0.taskHistory(key: "k", cursor: "c1", limit: 20) },
        Case(function: "adminJobs", operation: "GET /api/v2/admin/jobs") { _ = try await $0.adminJobs(cursor: "c1", limit: 20) },
        Case(function: "adminTask", operation: "GET /api/v2/admin/tasks/{key}") { _ = try await $0.adminTask(key: "backup") },

        Case(function: "nodeSummaries", operation: "GET /api/v2/admin/nodes/summary") { _ = try await $0.nodeSummaries() },
        Case(function: "nodeConfigurationVersions", operation: "GET /api/v2/admin/nodes") { _ = try await $0.nodeConfigurationVersions() },
        Case(function: "drainNode", operation: "POST /api/v2/admin/nodes/{id}/drain") { try await $0.drainNode(id: "n1") },
        Case(function: "resumeNode", operation: "POST /api/v2/admin/nodes/{id}/resume") { try await $0.resumeNode(id: "n1") },
        Case(function: "checkNode", operation: "POST /api/v2/admin/nodes/{id}/check") { try await $0.checkNode(id: "n1") },
        Case(function: "setNodeEnabled", operation: "PUT /api/v2/admin/nodes/{id}") { try await $0.setNodeEnabled(id: "n1", enabled: false, validator: "\"cfg\"") },

        Case(function: "backupsOverview", operation: "GET /api/v2/admin/backups") { _ = try await $0.backupsOverview() },
        Case(function: "startBackup", operation: "POST /api/v2/admin/backups") { try await $0.startBackup() },
        Case(function: "deleteBackup", operation: "DELETE /api/v2/admin/backups/{id}") { try await $0.deleteBackup(id: "b1") },

        Case(function: "pluginInstallations", operation: "GET /api/v2/admin/plugins/installations") { _ = try await $0.pluginInstallations() },
        Case(function: "restartPlugin", operation: "POST /api/v2/admin/plugins/installations/{id}/restart") { try await $0.restartPlugin(id: "p1") },
        Case(function: "setPluginEnabled", operation: "PUT /api/v2/admin/plugins/installations/{id}") { try await $0.setPluginEnabled(id: "p1", enabled: false) },
        Case(function: "applyPluginUpdate", operation: "POST /api/v2/admin/plugins/installations/{id}/update") { try await $0.applyPluginUpdate(id: "p1") },

        Case(function: "health", operation: "EXEMPT GET /api/v1/health") { _ = try await $0.health() },
        Case(function: "serverStatus", operation: "GET /api/v2/admin/server/status") { _ = try await $0.serverStatus() },
        Case(function: "adminStats", operation: "GET /api/v2/admin/stats") { _ = try await $0.adminStats(forceRefresh: true) },
        Case(function: "adminStats", operation: "GET /api/v2/admin/stats") { _ = try await $0.adminStats(forceRefresh: false) },
        Case(function: "systemResources", operation: "GET /api/v2/admin/system/resources") { _ = try await $0.systemResources() },
        Case(function: "dashboardStatus", operation: "GET /api/v2/admin/server/status") { _ = try await $0.dashboardStatus() },
        Case(function: "buildInfo", operation: "GET /api/v2/admin/system/build") { _ = try await $0.buildInfo() },
        Case(function: "listNodes", operation: "GET /api/v2/admin/nodes") { _ = try await $0.listNodes() },
        Case(function: "playbackActivity", operation: "GET /api/v2/admin/stats/playback-activity") { _ = try await $0.playbackActivity(hours: 24, refresh: false) },
        Case(function: "playbackActivity", operation: "GET /api/v2/admin/stats/playback-activity") { _ = try await $0.playbackActivity(hours: 720, refresh: true) },
        Case(function: "playbackActivity", operation: "GET /api/v2/admin/stats/playback-activity") { _ = try await $0.playbackActivity(hours: 100_000, refresh: false) },
        Case(function: "timeseries", operation: "GET /api/v2/admin/stats/timeseries") { _ = try await $0.timeseries(hours: 1, refresh: false) },
        Case(function: "timeseries", operation: "GET /api/v2/admin/stats/timeseries") { _ = try await $0.timeseries(hours: 168, refresh: true) },
        Case(function: "timeseries", operation: "GET /api/v2/admin/stats/timeseries") { _ = try await $0.timeseries(hours: 0, refresh: false) },
        Case(function: "topActivity", operation: "GET /api/v2/admin/stats/top-activity") { _ = try await $0.topActivity(days: 7, limit: 5, refresh: false) },
        Case(function: "topActivity", operation: "GET /api/v2/admin/stats/top-activity") { _ = try await $0.topActivity(days: 90, limit: 500, refresh: true) },
        Case(function: "listLibraries", operation: "GET /api/v2/libraries") { _ = try await $0.listLibraries() },
        Case(function: "usersForDashboard", operation: "GET /api/v2/admin/users") { _ = try await $0.usersForDashboard() },
        Case(function: "recentPlayback", operation: "GET /api/v2/admin/playback-history") { _ = try await $0.recentPlayback(limit: 5) },
        Case(function: "recentPlayback", operation: "GET /api/v2/admin/playback-history") { _ = try await $0.recentPlayback(limit: 5000) },
        Case(function: "settings", operation: "GET /api/v2/admin/settings") { _ = try await $0.settings() },
        Case(function: "effectiveSettings", operation: "GET /api/v2/admin/settings/effective") { _ = try await $0.effectiveSettings() },
        Case(function: "updateSetting", operation: "PUT /api/v2/admin/settings/{key}") { _ = try await $0.updateSetting(key: "k", value: "v", validator: "\"v1\"") },
        Case(function: "requestServerRestart", operation: "POST /api/v2/admin/server/restart") { _ = try await $0.requestServerRestart() },
        Case(function: "restartKeys", operation: "GET /api/v2/admin/settings/restart-keys") { _ = try await $0.restartKeys() },
        Case(function: "sensitiveStatus", operation: "GET /api/v2/admin/settings/sensitive-status") { _ = try await $0.sensitiveStatus() },
        Case(function: "updateSettings", operation: "PUT /api/v2/admin/settings") { _ = try await $0.updateSettings(values: ["k": "v"], validator: "\"v1\"") },
        Case(function: "checkConnection", operation: "POST /api/v2/admin/settings/check/{kind}") { _ = try await $0.checkConnection(kind: "redis", values: ["redis.db": "1"], dirtyKeys: ["redis.db"]) },
        Case(function: "sendTestEmail", operation: "POST /api/v2/admin/email/test") { _ = try await $0.sendTestEmail(to: "a@example.test") },
        Case(function: "notificationServerChannels", operation: "GET /api/v2/admin/notifications/server-channels") { _ = try await $0.notificationServerChannels() },
        Case(function: "testServerChannel", operation: "POST /api/v2/admin/notifications/server-channels/{id}/test") { _ = try await $0.testServerChannel(id: "c1") },
        Case(function: "requestSettings", operation: "GET /api/v2/admin/request-settings") { _ = try await $0.requestSettings() },
        Case(function: "updateRequestSettings", operation: "PUT /api/v2/admin/request-settings") {
            _ = try await $0.updateRequestSettings(
                RequestSettings(requestsEnabled: true, globalMaxRequests: 5, globalWindowDays: 7, globalAutoApprovalEnabled: false, forceDualQuality: false, watchlistRequests: false),
                validator: "\"s1\""
            )
        },
        Case(function: "networkAccessProviders", operation: "GET /api/v2/network-access/capabilities") { _ = try await $0.networkAccessProviders() },
        Case(function: "networkAccessHosts", operation: "GET /api/v2/admin/network-access/{provider}/status") { _ = try await $0.networkAccessHosts(provider: "tailscale") },
        Case(function: "connectNetworkAccess", operation: "POST /api/v2/admin/network-access/{provider}/connect") { _ = try await $0.connectNetworkAccess(provider: "tailscale", hostIDs: ["api"]) },
        Case(function: "disconnectNetworkAccess", operation: "POST /api/v2/admin/network-access/{provider}/disconnect") { _ = try await $0.disconnectNetworkAccess(provider: "tailscale", hostIDs: ["api"]) },
        Case(function: "signInProviders", operation: "GET /api/v2/admin/plugins/installations") { _ = try await $0.signInProviders() },
        Case(function: "testSignInProvider", operation: "POST /api/v2/admin/plugins/installations/{id}/auth-binding/test") {
            _ = try await $0.testSignInProvider(SignInProvider(id: "3", name: "SSO", capabilityID: "oidc", enabled: true))
        },

        Case(function: "tenants", operation: "GET /api/bloem/v2/admin/platform/tenants") { _ = try await $0.tenants() },
        Case(function: "tenantMembers", operation: "GET /api/bloem/v2/admin/platform/tenants/{tenant_id}/members") { _ = try await $0.tenantMembers(tenantID: "t1") },

        Case(function: "users", operation: "GET /api/v2/admin/users") { _ = try await $0.users() },
        Case(function: "user", operation: "GET /api/v2/admin/users/{id}") { _ = try await $0.user(id: "1") },
        Case(function: "createUser", operation: "POST /api/v2/admin/users") { _ = try await $0.createUser(CreateUserRequest(username: "alice", email: "a@example.test", password: "pw", role: "user")) },
        Case(function: "updateUser", operation: "PUT /api/v2/admin/users/{id}") { try await $0.updateUser(id: "1", body: UpdateUserRequest(enabled: false), validator: "\"v1\"") },
        Case(function: "deleteUser", operation: "DELETE /api/v2/admin/users/{id}") { try await $0.deleteUser(id: "1", validator: "\"v1\"") },
        Case(function: "loginSessions", operation: "GET /api/v2/admin/users/{user_id}/login-sessions") { _ = try await $0.loginSessions(userID: "1") },
        Case(function: "revokeLoginSession", operation: "DELETE /api/v2/admin/users/{user_id}/login-sessions/{session_id}") { try await $0.revokeLoginSession(userID: "1", sessionID: "ls1") },
        Case(function: "revokeAllLoginSessions", operation: "DELETE /api/v2/admin/users/{user_id}/login-sessions") { _ = try await $0.revokeAllLoginSessions(userID: "1") },
        Case(function: "userDevices", operation: "GET /api/v2/admin/users/{id}/devices") { _ = try await $0.userDevices(userID: "1") },

        Case(function: "currentAccount", operation: "GET /api/v2/account/me") { _ = try await $0.currentAccount() },
        Case(function: "userCapabilities", operation: "GET /api/v2/admin/users/capabilities") { _ = try await $0.userCapabilities() },
        Case(function: "userPolicyDefaults", operation: "GET /api/v2/admin/users/policy-defaults") { _ = try await $0.userPolicyDefaults() },
        Case(function: "accessGroups", operation: "GET /api/v2/admin/access-groups") { _ = try await $0.accessGroups() },
        Case(function: "libraryChoices", operation: "GET /api/v2/libraries") { _ = try await $0.libraryChoices() },
        Case(function: "userProfiles", operation: "GET /api/v2/admin/users/{id}/profiles") { _ = try await $0.userProfiles(userID: "1") },
        Case(function: "userWatchSummary", operation: "GET /api/v2/admin/users/{id}/watch-summary") { _ = try await $0.userWatchSummary(userID: "1", days: 30) },
        Case(function: "userIPs", operation: "GET /api/v2/admin/users/{id}/ips") { _ = try await $0.userIPs(userID: "1", days: 30, limit: 50) },
        Case(function: "userDownloads", operation: "GET /api/v2/admin/users/{id}/downloads") { _ = try await $0.userDownloads(userID: "1", cursor: "c1") },
        Case(function: "userDownloads", operation: "GET /api/v2/admin/users/{id}/downloads") { _ = try await $0.userDownloads(userID: "1", cursor: nil) },
        Case(function: "userDownloadSummary", operation: "GET /api/v2/admin/users/{id}/downloads/summary") { _ = try await $0.userDownloadSummary(userID: "1") },
        Case(function: "requestPasswordReset", operation: "POST /api/v2/admin/users/{id}/password-reset") { _ = try await $0.requestPasswordReset(userID: "1") },
        Case(function: "requestPasswordReset", operation: "POST /api/v2/admin/users/{id}/password-reset") { _ = try await $0.requestPasswordReset(userID: "1", delivery: .link) },
        Case(function: "createUserProfile", operation: "POST /api/v2/admin/users/{id}/profiles") { _ = try await $0.createUserProfile(userID: "1", name: "Kids", pin: "1234") },
        Case(function: "createUserProfile", operation: "POST /api/v2/admin/users/{id}/profiles") { _ = try await $0.createUserProfile(userID: "1", name: "Guest", pin: nil) },
        Case(function: "renameUserProfile", operation: "PATCH /api/v2/admin/users/{id}/profiles/{profile_id}") { try await $0.renameUserProfile(userID: "1", profileID: "p1", name: "Teens") },
        Case(function: "setUserProfilePIN", operation: "PATCH /api/v2/admin/users/{id}/profiles/{profile_id}") { try await $0.setUserProfilePIN(userID: "1", profileID: "p1", pin: "4321") },
        Case(function: "clearUserProfilePIN", operation: "PATCH /api/v2/admin/users/{id}/profiles/{profile_id}") { try await $0.clearUserProfilePIN(userID: "1", profileID: "p1") },
        Case(function: "deleteUserProfile", operation: "DELETE /api/v2/admin/users/{id}/profiles/{profile_id}") { try await $0.deleteUserProfile(userID: "1", profileID: "p1") },
        Case(function: "watchingNow", operation: "GET /api/v2/admin/sessions") { _ = try await $0.watchingNow(userID: "7") },
        Case(function: "requestCapabilities", operation: "GET /api/v2/admin/requests/capabilities") { _ = try await $0.requestCapabilities() },
        Case(function: "apiKeysPage", operation: "GET /api/v2/admin/api-keys") { _ = try await $0.apiKeysPage(cursor: nil) },
        Case(function: "apiKeysPage", operation: "GET /api/v2/admin/api-keys") { _ = try await $0.apiKeysPage(cursor: "c1") },
        Case(function: "apiKeyVersion", operation: "GET /api/v2/admin/api-keys/{id}") { _ = try await $0.apiKeyVersion(id: "7") },
        Case(function: "deleteAPIKey", operation: "DELETE /api/v2/admin/api-keys/{id}") { try await $0.deleteAPIKey(id: "7", validator: "\"v1\"") },
        Case(function: "userSettingValues", operation: "GET /api/v2/admin/users/{id}/settings/values") { _ = try await $0.userSettingValues(userID: "1") },
        Case(function: "setUserSettingValue", operation: "PUT /api/v2/admin/users/{id}/settings/values/{key}") {
            try await $0.setUserSettingValue(userID: "1", key: "playback.autoplay", identity: SettingIdentity(scope: "profile_device", profileID: "p1", deviceID: "d1"), value: .bool(true))
        },
        Case(function: "deleteUserSettingValue", operation: "DELETE /api/v2/admin/users/{id}/settings/values/{key}") {
            try await $0.deleteUserSettingValue(userID: "1", key: "playback.autoplay", identity: SettingIdentity(scope: "profile_library", profileID: "p1", libraryID: "l1"))
        },
        Case(function: "settingsContract", operation: "GET /api/v2/settings/contract") { _ = try await $0.settingsContract() },
        // Organization mode: the account token lists and mints; the pass reaches every /admin/organization route.
        Case(function: "listOrganizationMemberships", operation: "GET /api/bloem/v2/organizations") { _ = try await $0.listOrganizationMemberships() },
        Case(function: "mintAdminSession", operation: "POST /api/bloem/v2/admin/session") { _ = try await $0.mintAdminSession(AdminSessionRequest(scope: "organization", organizationID: "o1")) },
        Case(function: "organizationOverview", operation: "GET /api/bloem/v2/admin/organization/overview") { _ = try await $0.organizationOverview() },
        Case(function: "listOrganizationPeople", operation: "GET /api/bloem/v2/admin/organization/people/") {
            _ = try await $0.listOrganizationPeople(
                filter: PeopleFilter(query: "sam", statuses: ["active", "suspended"], groupID: 3, sort: "email", activeSince: "2026-11-01T00:00:00Z"),
                cursor: "c1"
            )
        },
        Case(function: "listOrganizationPeople", operation: "GET /api/bloem/v2/admin/organization/people/") { _ = try await $0.listOrganizationPeople(filter: PeopleFilter(), cursor: nil) },
        Case(function: "organizationPerson", operation: "GET /api/bloem/v2/admin/organization/people/{account_id}/") { _ = try await $0.organizationPerson(accountID: 5) },
        Case(function: "setOrganizationMembershipStatus", operation: "PATCH /api/bloem/v2/admin/organization/people/{account_id}/memberships/current") { _ = try await $0.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4) },
        Case(function: "setOrganizationProfileGroup", operation: "PATCH /api/bloem/v2/admin/organization/people/{account_id}/profiles/{profile_id}") { _ = try await $0.setOrganizationProfileGroup(accountID: 5, profileID: "p1", groupID: 3, revision: 4) },
        Case(function: "listOrganizationGroups", operation: "GET /api/bloem/v2/admin/organization/groups/") { _ = try await $0.listOrganizationGroups() },
        Case(function: "listOrganizationLibraries", operation: "GET /api/bloem/v2/admin/organization/libraries") { _ = try await $0.listOrganizationLibraries() },
        Case(function: "setOrganizationEntitlementStatus", operation: "PUT /api/bloem/v2/admin/organization/entitlements/{folder_id}") { _ = try await $0.setOrganizationEntitlementStatus(folderID: 2, status: "suspended", revision: 9) },
        Case(function: "deleteOrganizationEntitlement", operation: "DELETE /api/bloem/v2/admin/organization/entitlements/{folder_id}") { try await $0.deleteOrganizationEntitlement(folderID: 2, revision: 9) },
        Case(function: "listOrganizationInvitations", operation: "GET /api/bloem/v2/admin/organization/invitations") { _ = try await $0.listOrganizationInvitations() },
        Case(function: "createOrganizationInvitation", operation: "POST /api/bloem/v2/admin/organization/invitations") { _ = try await $0.createOrganizationInvitation(CreateOrganizationInvitation(email: "new@example.test", expectedRevision: 7, accessGroupID: 3, note: "hi")) },
        Case(function: "resendOrganizationInvitation", operation: "POST /api/bloem/v2/admin/organization/invitations/{id}/resend") { _ = try await $0.resendOrganizationInvitation(id: "i1", revision: 7) },
        Case(function: "revokeOrganizationInvitation", operation: "DELETE /api/bloem/v2/admin/organization/invitations/{id}") { try await $0.revokeOrganizationInvitation(id: "i1", revision: 7) },
        Case(function: "listOrganizationActivity", operation: "GET /api/bloem/v2/admin/organization/activity") { _ = try await $0.listOrganizationActivity(cursor: "c1") },
        Case(function: "listOrganizationCohorts", operation: "GET /api/bloem/v2/admin/organization/entitlement-cohorts") { _ = try await $0.listOrganizationCohorts(includeArchived: true) },
        Case(function: "listOrganizationPolicyDecisions", operation: "GET /api/bloem/v2/admin/organization/policy-decisions") { _ = try await $0.listOrganizationPolicyDecisions(cursor: "c1", limit: 50) },
        Case(function: "organizationPolicyDecision", operation: "GET /api/bloem/v2/admin/organization/policy-decisions/{id}") { _ = try await $0.organizationPolicyDecision(id: 1) },
        Case(function: "createOrganizationSelection", operation: "POST /api/bloem/v2/admin/organization/people/selections") { _ = try await $0.createOrganizationSelection(filter: PeopleFilter(query: "sam", statuses: ["active"], groupID: 3)) },
        Case(function: "startOrganizationBulkJob", operation: "POST /api/bloem/v2/admin/organization/people/bulk-jobs") { _ = try await $0.startOrganizationBulkJob(selectionToken: "tok", kind: "assign_group", groupID: 3) },
        Case(function: "organizationBulkJob", operation: "GET /api/bloem/v2/admin/organization/people/bulk-jobs/{job_id}") { _ = try await $0.organizationBulkJob(id: "job-1") },
        Case(function: "createOrganizationGroup", operation: "POST /api/bloem/v2/admin/organization/groups/") { _ = try await $0.createOrganizationGroup(name: "Family", revision: 7) },
        Case(function: "updateOrganizationGroup", operation: "PUT /api/bloem/v2/admin/organization/groups/{id}") {
            _ = try await $0.updateOrganizationGroup(
                id: 3,
                body: AccessGroupDraft(group: OrganizationAccessGroup(id: "3", name: "Family")).body(revision: 7)
            )
        },
        Case(function: "deleteOrganizationGroup", operation: "DELETE /api/bloem/v2/admin/organization/groups/{id}") { _ = try await $0.deleteOrganizationGroup(id: 3, revision: 7) },
        // Organization support (organization_support_v1): reset links, sign-outs, profiles, streams, support access.
        Case(function: "organizationSupportCapabilities", operation: "GET /api/bloem/v2/admin/organization/support-capabilities") { _ = try await $0.organizationSupportCapabilities() },
        // The organization live socket (docs/design.md) is not in the generated contract yet.
        Case(function: "createOrganizationLiveTicket", operation: "EXEMPT POST /api/bloem/v2/admin/organization/live/ticket") { _ = try await $0.createOrganizationLiveTicket() },
        Case(function: "bloemCapabilities", operation: "GET /api/bloem/v2/capabilities") { _ = try await $0.bloemCapabilities() },
        Case(function: "registerPushDevice", operation: "POST /api/bloem/v2/admin/push/devices") {
            _ = try await $0.registerPushDevice(PushRegisterRequest(
                installationID: "install-0001", platform: "apple", token: "ab12cd", apnsEnvironment: "sandbox",
                apnsTopic: "com.bloemstudios.admin", disabledKinds: ["admin.scan_failed"]
            ))
        },
        Case(function: "setPushKinds", operation: "PATCH /api/bloem/v2/admin/push/devices/{device_id}/kinds") { _ = try await $0.setPushKinds(deviceID: "d1", kinds: ["admin.scan_failed": false]) },
        Case(function: "setPushWidgets", operation: "PUT /api/bloem/v2/admin/push/devices/{device_id}/widgets") { _ = try await $0.setPushWidgets(deviceID: "d1", report: WidgetReport(placed: true, channels: [.nodes])) },
        Case(function: "deletePushDevice", operation: "DELETE /api/bloem/v2/admin/push/devices/{device_id}") { try await $0.deletePushDevice(deviceID: "d1") },
        Case(function: "issueOrganizationPasswordReset", operation: "POST /api/bloem/v2/admin/organization/people/{account_id}/password-reset") { _ = try await $0.issueOrganizationPasswordReset(accountID: 5, delivery: .email, revision: 4) },
        Case(function: "issueOrganizationPasswordReset", operation: "POST /api/bloem/v2/admin/organization/people/{account_id}/password-reset") { _ = try await $0.issueOrganizationPasswordReset(accountID: 5, delivery: .link, revision: 4) },
        Case(function: "organizationPersonSessions", operation: "GET /api/bloem/v2/admin/organization/people/{account_id}/sessions") { _ = try await $0.organizationPersonSessions(accountID: 5) },
        Case(function: "signOutOrganizationPersonEverywhere", operation: "DELETE /api/bloem/v2/admin/organization/people/{account_id}/sessions") { _ = try await $0.signOutOrganizationPersonEverywhere(accountID: 5, revision: 4) },
        Case(function: "signOutOrganizationPersonSession", operation: "DELETE /api/bloem/v2/admin/organization/people/{account_id}/sessions/{session_id}") { try await $0.signOutOrganizationPersonSession(accountID: 5, sessionID: "s1") },
        Case(function: "organizationPersonDevices", operation: "GET /api/bloem/v2/admin/organization/people/{account_id}/devices") { _ = try await $0.organizationPersonDevices(accountID: 5) },
        Case(function: "signOutOrganizationPersonDevice", operation: "DELETE /api/bloem/v2/admin/organization/people/{account_id}/devices/{device_id}") { try await $0.signOutOrganizationPersonDevice(accountID: 5, deviceID: "d1") },
        Case(function: "createOrganizationProfile", operation: "POST /api/bloem/v2/admin/organization/people/{account_id}/profiles") { _ = try await $0.createOrganizationProfile(accountID: 5, name: "Kids", groupID: 3) },
        Case(function: "createOrganizationProfile", operation: "POST /api/bloem/v2/admin/organization/people/{account_id}/profiles") { _ = try await $0.createOrganizationProfile(accountID: 5, name: "Kids", groupID: nil) },
        Case(function: "renameOrganizationProfile", operation: "PATCH /api/bloem/v2/admin/organization/people/{account_id}/profiles/{profile_id}/details") { _ = try await $0.renameOrganizationProfile(accountID: 5, profileID: "p1", name: "Den", revision: 2) },
        Case(function: "clearOrganizationProfilePIN", operation: "DELETE /api/bloem/v2/admin/organization/people/{account_id}/profiles/{profile_id}/pin") { _ = try await $0.clearOrganizationProfilePIN(accountID: 5, profileID: "p1", revision: 2) },
        Case(function: "removeOrganizationProfile", operation: "DELETE /api/bloem/v2/admin/organization/people/{account_id}/profiles/{profile_id}") { try await $0.removeOrganizationProfile(accountID: 5, profileID: "p1", revision: 2) },
        Case(function: "listOrganizationStreams", operation: "GET /api/bloem/v2/admin/organization/streams") { _ = try await $0.listOrganizationStreams(cursor: "c1") },
        Case(function: "listOrganizationStreams", operation: "GET /api/bloem/v2/admin/organization/streams") { _ = try await $0.listOrganizationStreams(cursor: nil, limit: 1) },
        Case(function: "stopOrganizationStream", operation: "POST /api/bloem/v2/admin/organization/streams/{session_id}/stop") { _ = try await $0.stopOrganizationStream(sessionID: "s1") },
        Case(function: "messageOrganizationStream", operation: "POST /api/bloem/v2/admin/organization/streams/{session_id}/message") { _ = try await $0.messageOrganizationStream(sessionID: "s1", title: "Hi", message: "Closing soon", identity: identity) },
        Case(function: "closeOrganizationSupportAccess", operation: "DELETE /api/bloem/v2/admin/organization/support-access") { try await $0.closeOrganizationSupportAccess() },
        Case(function: "mintAdminSession", operation: "POST /api/bloem/v2/admin/session") {
            _ = try await $0.mintAdminSession(AdminSessionRequest(scope: "organization", organizationID: "o1", support: .opening(reason: "Locked out; helping her")))
        },
        Case(function: "mintAdminSession", operation: "POST /api/bloem/v2/admin/session") { _ = try await $0.mintAdminSession(AdminSessionRequest(scope: "platform", organizationID: nil)) },
        Case(function: "listPlatformOrganizations", operation: "GET /api/bloem/v2/admin/platform/organizations/") { _ = try await $0.listPlatformOrganizations(query: "acme", cursor: "c1") },
        Case(function: "listPlatformOrganizations", operation: "GET /api/bloem/v2/admin/platform/organizations/") { _ = try await $0.listPlatformOrganizations(query: "acme", status: "suspended", cursor: nil, limit: 50) },
        Case(function: "platformOrganization", operation: "GET /api/bloem/v2/admin/platform/organizations/{id}/") { _ = try await $0.platformOrganization(id: "o1") },
        Case(function: "platformOrganizationMemberships", operation: "GET /api/bloem/v2/admin/platform/organizations/{id}/memberships") { _ = try await $0.platformOrganizationMemberships(id: "o1", cursor: "c1", limit: 100) },
        Case(function: "suspendPlatformOrganization", operation: "POST /api/bloem/v2/admin/platform/organizations/{id}/suspend") { _ = try await $0.suspendPlatformOrganization(id: "o1", expectedRevision: 7) },
        Case(function: "reactivatePlatformOrganization", operation: "POST /api/bloem/v2/admin/platform/organizations/{id}/reactivate") { _ = try await $0.reactivatePlatformOrganization(id: "o1", expectedRevision: 7) },
        Case(function: "platformOrganizationEntitlement", operation: "GET /api/bloem/v2/admin/platform/organizations/{id}/entitlement") { _ = try await $0.platformOrganizationEntitlement(id: "o1") },
        Case(function: "platformEntitlementTemplates", operation: "GET /api/bloem/v2/admin/platform/entitlement-templates") { _ = try await $0.platformEntitlementTemplates() },
        Case(function: "dryRunPlatformOrganizationEntitlement", operation: "POST /api/bloem/v2/admin/platform/organizations/{id}/entitlement/dry-run") { _ = try await $0.dryRunPlatformOrganizationEntitlement(id: "o1", templateKey: "premium", templateRevision: 2) },
        Case(function: "applyPlatformOrganizationEntitlement", operation: "POST /api/bloem/v2/admin/platform/organizations/{id}/entitlement/apply") { _ = try await $0.applyPlatformOrganizationEntitlement(id: "o1", templateKey: "premium", templateRevision: 2, token: "t", idempotencyKey: "k") },
    ]

    /// Auth calls build their own client, so they take the stub session instead of an `APIClient`.
    private struct AuthCase {
        let function: String
        let operation: String
        /// A schema-complete success body, so the call decodes it; nil keeps the generic stub.
        let response: String?
        let call: @MainActor @Sendable (URLSession) async throws -> Void
    }

    private static let authCases: [AuthCase] = [
        AuthCase(function: "login", operation: "POST /api/v2/auth/login", response: nil) { session in
            _ = try await AuthAPI.login(baseURL: baseURL, username: "admin", password: "pw", session: session)
        },
        AuthCase(function: "refresh", operation: "POST /api/v2/auth/refresh", response: nil) { session in
            _ = try await AuthAPI.refresh(baseURL: baseURL, refreshToken: "r", session: session)
        },
        AuthCase(function: "serverIdentity", operation: "GET /api/v2/system/identity", response: #"{"server_id":"3f2a9d5e-6b1c-4c7e-9a0d-2f4b8c1e7a35"}"#) { session in
            _ = try await AuthAPI.serverIdentity(baseURL: baseURL, session: session)
        },
        AuthCase(
            function: "authProviders",
            operation: "GET /api/v2/auth/providers",
            response: #"{"password_login":true,"items":[{"id":"local","display_name":"Silo account","mode":"credentials","default":true},{"id":"26","display_name":"Corp SSO","mode":"oauth","default":false,"installation_id":"3","icon_url":"https://plugins.example.test/icon.svg","native_start_path":"/api/v2/auth/oauth/3/native/start"},{"id":"net","display_name":"Home network","mode":"network","default":false,"network_sign_in_path":"/api/v2/auth/network/5/sign-in","network_identity":{"display_name":"Alex","username":"alex"}}],"page":{"has_more":false}}"#
        ) { session in
            let providers = try await AuthAPI.authProviders(baseURL: baseURL, session: session)
            // The fixture decodes completely: a mismatch fails the call, which the contract run reports.
            guard providers.nativeOAuth.map(\.id) == ["26"] else { throw URLError(.cannotParseResponse) }
        },
        AuthCase(
            function: "completeOAuthLogin",
            operation: "POST /api/v2/auth/oauth/complete",
            response: #"{"access_token":"a","refresh_token":"r","expires_in":3600,"next":"/","user":{"id":"1","username":"admin","email":"admin@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#
        ) { session in
            let completion = try await AuthAPI.completeOAuthLogin(baseURL: baseURL, code: "c", verifier: "v", session: session)
            guard completion.user.id == "1" else { throw URLError(.cannotParseResponse) }
        },
    ]

    private func segmentsMatch(_ template: String, _ actual: String) -> Bool {
        let t = template.split(separator: "/", omittingEmptySubsequences: true)
        let a = actual.split(separator: "/", omittingEmptySubsequences: true)
        return t.count == a.count && zip(t, a).allSatisfy { ($0.hasPrefix("{") && !$1.isEmpty) || $0 == $1 }
    }

    /// The most specific template (fewest placeholders) that fits the method and path.
    private func findTemplate(_ contract: [String: [String: [String: Any]]], method: String, path: String) -> String? {
        contract.keys
            .filter { contract[$0]?[method.lowercased()] != nil && segmentsMatch($0, path) }
            .min { $0.filter { $0 == "{" }.count < $1.filter { $0 == "{" }.count }
    }

    private func check(
        _ request: URLRequest,
        body: Data?,
        function: String,
        expected: String,
        contract: [String: [String: [String: Any]]],
        into violations: inout [String]
    ) {
        let method = request.httpMethod ?? "GET"
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let path = components?.percentEncodedPath ?? ""
        let label = "\(function): \(method) \(path)"
        let template = findTemplate(contract, method: method, path: path)
        if expected.hasPrefix("EXEMPT ") {
            if template != nil { violations.append("\(label) is exempt but is in the contract; remove the exemption") }
            if "EXEMPT \(method) \(path)" != expected { violations.append("\(label) expected \(expected)") }
            return
        }
        guard let template, let operation = contract[template]?[method.lowercased()] else {
            violations.append("\(label) is not an operation in the contract")
            return
        }
        if "\(method) \(template)" != expected { violations.append("\(label) matched \(method) \(template), expected \(expected)") }
        let declared = Set(operation["query"] as? [String] ?? [])
        let required = Set(operation["required_query"] as? [String] ?? [])
        let items = components?.queryItems ?? []
        let sent = Set(items.map(\.name))
        for name in sent.subtracting(declared).sorted() {
            violations.append("\(label) sends undeclared query parameter '\(name)' (declared: \(declared.sorted()))")
        }
        for name in required.subtracting(sent).sorted() {
            violations.append("\(label) is missing required query parameter '\(name)'")
        }
        let bounds = operation["query_bounds"] as? [String: [String: Double]] ?? [:]
        for item in items {
            guard let limits = bounds[item.name], let text = item.value, let value = Double(text) else { continue }
            if let min = limits["min"], value < min { violations.append("\(label) sends \(item.name)=\(text), below the declared minimum \(min)") }
            if let max = limits["max"], value > max { violations.append("\(label) sends \(item.name)=\(text), above the declared maximum \(max)") }
        }
        if operation["body_required"] as? Bool == true {
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            let nonEmpty = object != nil && (object as? String).map { !$0.isEmpty } ?? true
            if !nonEmpty { violations.append("\(label) requires a JSON body but sent '\(body.flatMap { String(data: $0, encoding: .utf8) } ?? "")'") }
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.hasPrefix("application/json") { violations.append("\(label) requires a JSON body but sent Content-Type '\(contentType)'") }
        }
    }

    /// Runs one call against a fresh stub. Decoding the stub's body may fail; only the requests matter here.
    private func run(
        function: String,
        expected: String,
        contract: [String: [String: [String: Any]]],
        into violations: inout [String],
        response: String? = nil,
        call: (URLSession, APIClient) async throws -> Void
    ) async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let status = expected.hasPrefix("EXEMPT ") ? 200 : successStatus(expected, contract)
        http.state.responseStatus = status
        http.state.responseData = status == 204 ? Data() : Data((response ?? #"{"items":[]}"#).utf8)
        let client = APIClient(baseURL: Self.baseURL, accessToken: "tok", session: http.session)
        _ = try? await call(http.session, client)
        let requests = http.state.requestLog
        if requests.isEmpty { violations.append("\(function) sent no request") }
        for (index, request) in requests.enumerated() {
            let path = request.url?.path ?? ""
            let sameRoute = requests[..<index].filter { $0.url?.path == path }.count
            let body = http.state.body(path: path, requestIndex: sameRoute)
            check(request, body: body, function: function, expected: expected, contract: contract, into: &violations)
        }
    }

    private func successStatus(_ expected: String, _ contract: [String: [String: [String: Any]]]) -> Int {
        let parts = expected.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let operation = contract[parts[1]]?[parts[0].lowercased()],
              let first = (operation["success"] as? [String])?.first, let code = Int(first) else { return 200 }
        return code
    }

    func testEveryAPIFunctionSendsRequestsTheContractDeclares() async throws {
        let contract = try loadContract()
        var violations: [String] = []
        for testCase in Self.cases {
            await run(function: testCase.function, expected: testCase.operation, contract: contract, into: &violations) { _, client in
                try await testCase.call(client)
            }
        }
        for testCase in Self.authCases {
            await run(function: testCase.function, expected: testCase.operation, contract: contract, into: &violations, response: testCase.response) { session, _ in
                try await testCase.call(session)
            }
        }
        XCTAssertEqual(violations, [], "Contract violations")
    }

    func testEveryAPIFunctionHasAContractCase() throws {
        // Collections.swift and APIPath.swift hold paging and path helpers, not routes. HealthProbe.swift is
        // the unauthenticated reachability check the widgets share; its route is the `health` case below.
        // WidgetServerAPI.swift is the widgets' own read-only client: its routes (sessions, request counts,
        // libraries, nodes and the two request actions) are cases above, and WidgetFetcherTests covers its mapping.
        // PushDisplayAPI.swift is the notification extension's client, which uses a device token instead of a
        // sign-in: its two routes are checked against the contract in PushDisplayAPITests.
        let helperFiles: Set<String> = [
            "Networking/API/Collections.swift", "Networking/API/APIPath.swift", "Networking/API/HealthProbe.swift",
            "Networking/API/WidgetServerAPI.swift", "Networking/API/PushDisplayAPI.swift",
        ]
        let declaration = try NSRegularExpression(pattern: #"(?:^|\s)func\s+(\w+)"#)
        var functions = Set<String>()
        for file in try SourceTree.appSources()
        where (file.path.hasPrefix("Networking/API/") && !helperFiles.contains(file.path)) || file.path == "Networking/AuthAPI.swift" {
            for line in file.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("private ") || trimmed.hasPrefix("fileprivate ") { continue }
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = declaration.firstMatch(in: trimmed, range: range), let name = Range(match.range(at: 1), in: trimmed) {
                    functions.insert(String(trimmed[name]))
                }
            }
        }
        let covered = Set(Self.cases.map(\.function) + Self.authCases.map(\.function))
        XCTAssertGreaterThan(functions.count, 30)
        XCTAssertEqual(functions.subtracting(covered).sorted(), [], "API functions without a case in APIContractTests")
        XCTAssertEqual(covered.subtracting(functions).sorted(), [], "Cases for functions that no longer exist")
    }
}
