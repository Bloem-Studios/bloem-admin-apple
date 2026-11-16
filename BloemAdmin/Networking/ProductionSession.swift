import Foundation

enum ProductionSession {
#if DEBUG
    /// UI-test fixtures (`SiloServerUITestFixture`) put an in-process server in front of the network. Empty in normal use.
    nonisolated(unsafe) static var debugProtocolClasses: [AnyClass] = []
#endif

    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
#if DEBUG
        if !debugProtocolClasses.isEmpty {
            configuration.protocolClasses = debugProtocolClasses + (configuration.protocolClasses ?? [])
        }
#endif
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(
            configuration: configuration,
            delegate: RedirectRejectingSessionDelegate(),
            delegateQueue: nil
        )
    }
}

extension ProductionSession {
    /// The configuration for one realtime socket: the same rules (ephemeral, no cookies), but no short
    /// resource limit, because the socket is meant to stay open for minutes.
    static func socketConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return configuration
    }
}

private final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
