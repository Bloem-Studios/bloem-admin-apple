import Foundation

struct APIError: Error, Equatable, Sendable {
    let statusCode: Int
    let code: String?
    let message: String
    let retryAfter: String?
    let requestIdentity: RequestIdentity?
    /// `X-Silo-Latest-Sequence` on a 409: the session's latest applied command sequence (a stale refusal).
    let latestSequence: Int64?
    /// The body's `reason`, when it names one: why a person is protected (`409 target_protected`).
    let reason: String?
    /// The body's `capability`, when it names one: what the server cannot do (`409 capability_not_configured`).
    let capability: String?

    init(
        statusCode: Int,
        code: String? = nil,
        message: String,
        retryAfter: String? = nil,
        requestIdentity: RequestIdentity? = nil,
        latestSequence: Int64? = nil,
        reason: String? = nil,
        capability: String? = nil
    ) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.requestIdentity = requestIdentity
        self.latestSequence = latestSequence
        self.reason = reason
        self.capability = capability
    }
}

enum ServerRecoveryAction: Equatable, Sendable {
    case signIn
    case retry
    case none
}

/// Identifies which request should be resumed after a section-level sign-in.
/// Paginated sections must continue their failed page instead of resetting
/// accumulated content with a first-page reload.
enum ServerSectionReauthenticationOrigin: Equatable, Sendable {
    case initialLoad
    case pagination
}

/// The access gate's presentation state. Failure categories stay distinct so
/// the UI never asks for credentials when the server is merely offline,
/// incompatible, unavailable, or rejecting a non-admin account.
enum AdminAccessOutcome: Equatable, Sendable {
    case checking
    case authorized
    /// Not a platform administrator, but administers at least one organization: admitted to organization mode.
    case organizationOnly
    case signedOut
    case forbidden
    case connectivity
    case incompatibleResponse
    case serverFailure

    var recoveryAction: ServerRecoveryAction {
        switch self {
        case .signedOut: .signIn
        case .connectivity, .incompatibleResponse, .serverFailure: .retry
        case .checking, .authorized, .organizationOnly, .forbidden: .none
        }
    }

    var requestsCredentials: Bool { recoveryAction == .signIn }
    var canRetry: Bool { recoveryAction == .retry }
    /// The gate's own pages offer Retry wherever the account cannot move on: also at No access, where
    /// the role may have been restored since (the All servers sections have nothing to retry there).
    var gateOffersRetry: Bool { canRetry || self == .forbidden }
}

/// A typed, per-server failure retained by `fanOut` and aggregate view
/// models. The request identity from authentication failures is preserved so
/// each server's session state can still reject stale failures and expire only
/// the credential that actually failed.
enum ServerSectionFailure: Error, Equatable, Sendable, LocalizedError {
    enum Kind: Equatable, Sendable {
        case signedOut
        case forbidden
        case connectivity
        case incompatibleResponse
        case serverFailure
    }

    case signedOut(message: String, requestIdentity: RequestIdentity?)
    case forbidden(message: String, requestIdentity: RequestIdentity?)
    case connectivity(message: String)
    case incompatibleResponse(message: String)
    case serverFailure(statusCode: Int?, message: String)

    var kind: Kind {
        switch self {
        case .signedOut: .signedOut
        case .forbidden: .forbidden
        case .connectivity: .connectivity
        case .incompatibleResponse: .incompatibleResponse
        case .serverFailure: .serverFailure
        }
    }

    var outcome: AdminAccessOutcome {
        switch self {
        case .signedOut: .signedOut
        case .forbidden: .forbidden
        case .connectivity: .connectivity
        case .incompatibleResponse: .incompatibleResponse
        case .serverFailure: .serverFailure
        }
    }

    var recoveryAction: ServerRecoveryAction { outcome.recoveryAction }
    var requestsCredentials: Bool { outcome.requestsCredentials }
    var canRetry: Bool { outcome.canRetry }

    var message: String {
        switch self {
        case .signedOut(let message, _),
             .forbidden(let message, _),
             .connectivity(let message),
             .incompatibleResponse(let message),
             .serverFailure(_, let message):
            message
        }
    }

    var errorDescription: String? { message }

    /// The same failure with other text; the kind, status and request identity stay.
    func replacingMessage(_ message: String) -> ServerSectionFailure {
        switch self {
        case .signedOut(_, let identity): .signedOut(message: message, requestIdentity: identity)
        case .forbidden(_, let identity): .forbidden(message: message, requestIdentity: identity)
        case .connectivity: .connectivity(message: message)
        case .incompatibleResponse: .incompatibleResponse(message: message)
        case .serverFailure(let statusCode, _): .serverFailure(statusCode: statusCode, message: message)
        }
    }

    /// What a page that could not load is titled, by kind.
    var title: String {
        switch self {
        case .signedOut: String(localized: "Signed out")
        case .forbidden: String(localized: "No access")
        case .connectivity: String(localized: "Can't reach the server")
        case .incompatibleResponse: String(localized: "Unexpected response")
        case .serverFailure(let statusCode, _):
            if let statusCode, statusCode > 0 { String(localized: "Server error \(statusCode)") } else { String(localized: "Server error") }
        }
    }

    @MainActor
    func belongsToCurrentSession(_ sessionState: ServerScopedSession?) -> Bool {
        let identity: RequestIdentity?
        switch self {
        case .signedOut(_, let requestIdentity), .forbidden(_, let requestIdentity):
            identity = requestIdentity
        case .connectivity, .incompatibleResponse, .serverFailure:
            identity = nil
        }
        guard let identity else { return true }
        return sessionState?.isCurrentRequestIdentity(identity) ?? true
    }

    /// Recreates the authentication/server API error shape consumed by the
    /// existing per-domain view models, retaining their request-identity
    /// side effects while aggregate presentation uses this typed value.
    var applicationError: Error {
        switch self {
        case .signedOut(let message, let identity):
            APIError(statusCode: 401, message: message, requestIdentity: identity)
        case .forbidden(let message, let identity):
            APIError(statusCode: 403, message: message, requestIdentity: identity)
        case .serverFailure(let statusCode, let message):
            APIError(statusCode: statusCode ?? -1, message: message)
        case .connectivity, .incompatibleResponse:
            self
        }
    }

    static func classify(_ error: Error, fallback: String) -> ServerSectionFailure {
        if let failure = error as? ServerSectionFailure {
            return failure
        }
        if let notSignedIn = error as? NotSignedInError {
            return .signedOut(
                message: notSignedIn.errorDescription ?? String(localized: "Not signed in"),
                requestIdentity: nil
            )
        }
        if let apiError = error as? APIError {
            switch apiError.statusCode {
            case 401:
                return .signedOut(message: apiError.message, requestIdentity: apiError.requestIdentity)
            case 403:
                return .forbidden(message: apiError.message, requestIdentity: apiError.requestIdentity)
            default:
                return .serverFailure(statusCode: apiError.statusCode, message: apiError.message)
            }
        }
        if error is DecodingError {
            return .incompatibleResponse(
                message: String(localized: "The server returned an incompatible response")
            )
        }
        if let urlError = error as? URLError {
            let message: String
            switch urlError.code {
            case .notConnectedToInternet:
                message = String(localized: "No internet connection")
            case .timedOut:
                message = String(localized: "Request timed out")
            default:
                message = fallback
            }
            return .connectivity(message: message)
        }
        return .serverFailure(statusCode: nil, message: fallback)
    }
}

/// Small generation guard shared by aggregate view models. It prevents a
/// slower poll from replacing a newer per-server retry's typed failure state,
/// while keeping every server's recovery independent.
struct ServerSectionRecoveryState: Sendable {
    private var generationByServer: [String: UInt64] = [:]
    private var failureByServer: [String: ServerSectionFailure] = [:]

    mutating func retainServers(_ serverIDs: Set<String>) {
        generationByServer = generationByServer.filter { serverIDs.contains($0.key) }
        failureByServer = failureByServer.filter { serverIDs.contains($0.key) }
    }

    mutating func begin(serverID: String) -> UInt64 {
        let current = generationByServer[serverID] ?? 0
        precondition(current < UInt64.max, "Server section recovery generation exhausted")
        let next = current + 1
        generationByServer[serverID] = next
        return next
    }

    @MainActor
    mutating func apply<T>(
        _ result: Result<T, ServerSectionFailure>,
        serverID: String,
        generation: UInt64,
        sessionState: ServerScopedSession? = nil
    ) -> Result<T, Error>? {
        guard generationByServer[serverID] == generation else { return nil }
        switch result {
        case .success(let value):
            failureByServer[serverID] = nil
            return .success(value)
        case .failure(let failure):
            guard failure.belongsToCurrentSession(sessionState) else { return nil }
            failureByServer[serverID] = failure
            return .failure(failure.applicationError)
        }
    }

    func failure(serverID: String) -> ServerSectionFailure? {
        failureByServer[serverID]
    }
}

extension APIError {
    /// Silo answers a retired `/api/v1` route with `410 client_upgrade_required`.
    var isClientUpgradeRequired: Bool {
        statusCode == 410 && code == "client_upgrade_required"
    }
}

extension ServerSectionFailure.Kind {
    var icon: BloemIcon {
        switch self {
        case .signedOut: .userRoundX
        case .forbidden: .lock
        case .connectivity: .wifiOff
        case .incompatibleResponse: .unplug
        case .serverFailure: .triangleAlert
        }
    }
}
