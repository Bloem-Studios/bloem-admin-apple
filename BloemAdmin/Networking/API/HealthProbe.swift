import Foundation

// The public reachability check: one GET /api/v1/health with no sign-in. It is used by the background
// check, the foreground check and the widgets, and is compiled into the widget extension, so it knows
// nothing about stored sign-ins and sends no credentials, cookies or body.

enum HealthFailure: Codable, Equatable, Sendable {
    case timedOut
    case cannotConnect
    case secureConnection
    case serverError(Int)
    case other

    /// A few plain words for a notification's detail line.
    var summary: String {
        switch self {
        case .timedOut: String(localized: "timed out")
        case .cannotConnect: String(localized: "could not connect")
        case .secureConnection: String(localized: "secure connection failed")
        case .serverError(let status): String(localized: "server error \(status)")
        case .other: String(localized: "no usable answer")
        }
    }
}

enum HealthProbeResult: Equatable, Sendable {
    case up
    case down(HealthFailure)
    /// The phone itself could not reach the internet (or the check was cancelled): says nothing about the
    /// server, so it is never counted.
    case inconclusive
}

protocol HealthChecking: Sendable {
    func check(baseURL: URL) async -> HealthProbeResult
}

struct HealthProbe: HealthChecking {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/health"

    let timeout: TimeInterval
    private let transport: Transport

    /// `transport` is only replaced by tests.
    init(timeout: TimeInterval = 10, transport: Transport? = nil) {
        self.timeout = timeout
        self.transport = transport ?? Self.liveTransport(timeout: timeout)
    }

    func check(baseURL: URL) async -> HealthProbeResult {
        do {
            let (_, response) = try await transport(Self.request(baseURL: baseURL, timeout: timeout))
            guard let http = response as? HTTPURLResponse else { return .down(.other) }
            return Self.classify(statusCode: http.statusCode)
        } catch {
            return Self.classify(error: error)
        }
    }

    static func request(baseURL: URL, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path
        components.query = nil
        components.fragment = nil
        var request = URLRequest(
            url: components.url ?? baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Any answer below 500 means something is listening, even a refusal from a proxy in front of the
    /// server. A 5xx is a server or gateway that is up but failing, which is down for this purpose.
    static func classify(statusCode: Int) -> HealthProbeResult {
        statusCode < 500 ? .up : .down(.serverError(statusCode))
    }

    static func classify(error: Error) -> HealthProbeResult {
        if error is CancellationError { return .inconclusive }
        guard let urlError = error as? URLError else { return .down(.other) }
        if urlError.networkUnavailableReason != nil { return .inconclusive }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cancelled:
            return .inconclusive
        case .timedOut:
            return .down(.timedOut)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return .down(.cannotConnect)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .down(.secureConnection)
        default:
            return .down(.other)
        }
    }

    /// An ephemeral session that keeps nothing (no cache, cookies or credential storage) and follows no
    /// redirect.
    static func liveTransport(timeout: TimeInterval) -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return { request in try await session.data(for: request) }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
