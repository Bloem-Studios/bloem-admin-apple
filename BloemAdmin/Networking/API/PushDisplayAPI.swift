import Foundation

// The two admin push routes that use a device's display token instead of a sign-in: reading the text of a
// notification pushed to this device, and retiring the device. The notification service extension runs while
// the phone is locked and holds no sign-in, so these calls are separate from `APIClient`. The display token
// opens nothing else. Compiled into the app and into the extension; HTTPS only, no redirects, no cookies,
// no cache.

/// The admin push routes. The registration calls in `PushAPI.swift` use the same constants.
enum PushPaths {
    static let base = "/api/bloem/v2/admin/push"
    static let devices = "\(base)/devices"

    static func content(_ contentID: String) -> String {
        "\(base)/content/\(APIPath.segment(contentID))"
    }

    static func kinds(deviceID: String) -> String {
        "\(devices)/\(APIPath.segment(deviceID))/kinds"
    }

    static func widgets(deviceID: String) -> String {
        "\(devices)/\(APIPath.segment(deviceID))/widgets"
    }

    static func device(_ deviceID: String) -> String {
        "\(devices)/\(APIPath.segment(deviceID))"
    }

    static func retire(deviceID: String) -> String {
        "\(devices)/\(APIPath.segment(deviceID))/retire"
    }
}

enum PushContentResult: Equatable, Sendable {
    case content(PushContent)
    /// The server does not know this notification for this device: expired, or the token was replaced or
    /// retired. Asking again will not help.
    case gone
    /// No usable answer: offline, a timeout, or a server error.
    case failed
}

enum PushRetireResult: Equatable, Sendable {
    /// The server stopped pushing to this device.
    case retired
    /// The server no longer knows the device or its token, so there is nothing left to stop.
    case gone
    case failed
}

protocol PushDisplayAPI: Sendable {
    func content(baseURL: URL, displayToken: String, contentID: String) async -> PushContentResult
    func retire(baseURL: URL, displayToken: String, deviceID: String) async -> PushRetireResult
}

struct URLSessionPushDisplayAPI: PushDisplayAPI {
    /// A push has seconds: the text must arrive well inside what iOS gives the extension.
    static let requestTimeout: TimeInterval = 8

    let session: URLSession

    init(session: URLSession = URLSessionPushDisplayAPI.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 2
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func content(baseURL: URL, displayToken: String, contentID: String) async -> PushContentResult {
        guard let request = Self.request(baseURL: baseURL, path: PushPaths.content(contentID), method: "GET", token: displayToken) else {
            return .failed
        }
        guard let (data, status) = await send(request) else { return .failed }
        switch status {
        case 200:
            guard let content = try? JSONDecoder().decode(PushContent.self, from: data) else { return .failed }
            return .content(content)
        case 401, 403, 404:
            return .gone
        default:
            return .failed
        }
    }

    func retire(baseURL: URL, displayToken: String, deviceID: String) async -> PushRetireResult {
        guard let request = Self.request(baseURL: baseURL, path: PushPaths.retire(deviceID: deviceID), method: "POST", token: displayToken) else {
            return .failed
        }
        guard let (_, status) = await send(request) else { return .failed }
        switch status {
        case 200...299: return .retired
        case 401, 404: return .gone
        default: return .failed
        }
    }

    private func send(_ request: URLRequest) async -> (Data, Int)? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        } catch {
            return nil
        }
    }

    /// The request for `path` on `baseURL`, or nil when the server address is not HTTPS or the path is not valid.
    static func request(baseURL: URL, path: String, method: String, token: String) -> URLRequest? {
        guard baseURL.scheme?.lowercased() == "https",
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let combined = basePath + path
        guard APIPath.isValidEncodedPath(combined) else { return nil }
        components.percentEncodedPath = combined
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
