import Foundation

actor APIClient {
    typealias CredentialProvider = @MainActor @Sendable () -> RequestCredential?

    private let baseURL: URL
    private let fixedAccessToken: String?
    private let credentialProvider: CredentialProvider?
    private let session: URLSession
    /// Remembers whether this server is a Bloem server (`BloemServerDetector`). A client built by `ServerStore` shares
    /// the store's; one built on its own has none and asks every time.
    nonisolated let bloemDetector: BloemServerDetector?

    init(baseURL: URL, accessToken: String?, session: URLSession? = nil, bloemDetector: BloemServerDetector? = nil) {
        self.baseURL = baseURL
        self.fixedAccessToken = accessToken
        self.credentialProvider = nil
        self.session = Self.resolveSession(session)
        self.bloemDetector = bloemDetector
    }

    init(baseURL: URL, credentialProvider: @escaping CredentialProvider, session: URLSession? = nil, bloemDetector: BloemServerDetector? = nil) {
        self.baseURL = baseURL
        self.fixedAccessToken = nil
        self.credentialProvider = credentialProvider
        self.session = Self.resolveSession(session)
        self.bloemDetector = bloemDetector
    }

    /// The server address this client talks to; the events socket URL derives from it.
    nonisolated var origin: URL { baseURL }

    /// POST with no body and a decoded answer (the events socket ticket).
    func postForResult<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "POST", body: Optional<EmptyBody>.none)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: Optional<EmptyBody>.none)
    }

    /// Query-param variant used by screens with server-side filters/pagination
    /// (Audit's cursor filters, Activity's limit/offset + user_id). Empty
    /// values are dropped so callers can build the dict unconditionally
    /// (e.g. an empty search field) without special-casing "no filter."
    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        try await send(path: path, method: "GET", body: Optional<EmptyBody>.none, query: query)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path: path, method: "POST", body: body)
    }

    func post(_ path: String) async throws {
        let _: EmptyResponse = try await send(path: path, method: "POST", body: Optional<EmptyBody>.none)
    }

    /// No-response-body variant, mirroring the no-body `post(_ path:)` and
    /// `put(_:body:)` overloads above. Used where only the ROUTE (and
    /// request body) is confirmed live and the success response shape isn't
    /// (e.g. create-user), so callers that only care whether the write
    /// succeeded don't decode a specific typed response.
    func post(_ path: String, body: some Encodable) async throws {
        let _: EmptyResponse = try await send(path: path, method: "POST", body: body)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path: path, method: "PUT", body: body)
    }

    /// No-response-body variant, mirroring the no-body `post(_ path:)`
    /// overload above. Only the ROUTES for the admin PUT endpoints were
    /// confirmed live against the real server; the exact success response
    /// shape (204, an envelope, etc.) was never confirmed, so callers that
    /// only care whether the write succeeded should use this instead of
    /// decoding into a specific typed response.
    func put(_ path: String, body: some Encodable) async throws {
        let _: EmptyResponse = try await send(path: path, method: "PUT", body: body)
    }

    func delete(_ path: String) async throws {
        let _: EmptyResponse = try await send(path: path, method: "DELETE", body: Optional<EmptyBody>.none)
    }

    /// DELETE that addresses one row by query (a stored setting's scope and ids).
    func delete(_ path: String, query: [String: String]) async throws {
        let _: EmptyResponse = try await send(path: path, method: "DELETE", body: Optional<EmptyBody>.none, query: query)
    }

    /// PUT that addresses one row by query; the answer's body is not needed.
    func put(_ path: String, query: [String: String], body: some Encodable) async throws {
        let _: EmptyResponse = try await send(path: path, method: "PUT", body: body, query: query)
    }

    /// PATCH with a JSON body and a decoded answer (the organization people routes).
    func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path: path, method: "PATCH", body: body)
    }

    /// DELETE that carries a JSON body (`expected_revision`) and answers 204.
    func delete(_ path: String, body: some Encodable) async throws {
        let _: EmptyResponse = try await send(path: path, method: "DELETE", body: body)
    }

    /// DELETE that carries a JSON body and answers with one.
    func deleteDecoding<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await send(path: path, method: "DELETE", body: body)
    }

    /// DELETE whose success response carries a body (a count of what was removed, say).
    func deleteDecoding<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "DELETE", body: Optional<EmptyBody>.none)
    }

    /// GET that also returns the response's `ETag`, for a later `If-Match` write.
    func getWithValidator<T: Decodable>(_ path: String) async throws -> (T, String?) {
        try await sendWithValidator(path: path, method: "GET", body: Optional<EmptyBody>.none)
    }

    /// Conditional write: sends `If-Match` and, like every write here, is never replayed
    /// after a 401. A 412 surfaces as an `APIError` for the caller to turn into a conflict.
    func putConditional(_ path: String, body: some Encodable, validator: String) async throws {
        let _: EmptyResponse = try await send(
            path: path, method: "PUT", body: body, headers: ["If-Match": validator]
        )
    }

    /// `putConditional` for a route that answers with a body (a receipt).
    func putConditionalDecoding<T: Decodable>(_ path: String, body: some Encodable, validator: String) async throws -> T {
        try await send(path: path, method: "PUT", body: body, headers: ["If-Match": validator])
    }

    /// `putConditionalDecoding` that also returns the `ETag` the write answered with: the validator of the
    /// state the write produced, for the next conditional write.
    func putConditionalDecodingWithValidator<T: Decodable>(_ path: String, body: some Encodable, validator: String) async throws -> (T, String?) {
        try await sendWithValidator(path: path, method: "PUT", body: body, headers: ["If-Match": validator])
    }

    func deleteConditional(_ path: String, validator: String) async throws {
        let _: EmptyResponse = try await send(
            path: path, method: "DELETE", body: Optional<EmptyBody>.none, headers: ["If-Match": validator]
        )
    }

    private static func resolveSession(_ session: URLSession?) -> URLSession {
        guard let session, session !== URLSession.shared else {
            return ProductionSession.make()
        }
        return session
    }

    private func send<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B?,
        query: [String: String] = [:],
        headers: [String: String] = [:]
    ) async throws -> T {
        let (data, _) = try await perform(path: path, method: method, body: body, query: query, headers: headers)
        return try decode(data)
    }

    private func sendWithValidator<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B?,
        headers: [String: String] = [:]
    ) async throws -> (T, String?) {
        let (data, response) = try await perform(path: path, method: method, body: body, query: [:], headers: headers)
        return (try decode(data), response.value(forHTTPHeaderField: "ETag"))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if data.isEmpty, T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder.iso8601.decode(T.self, from: data)
    }

    /// `path` is already percent-encoded (see `APIPath.segment`) and is never decoded or re-encoded.
    private func requestURL(path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw Self.invalidPath
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let suffix = path.hasPrefix("/") ? path : "/" + path
        let combined = basePath + suffix
        // Setting an invalid percent-encoded path on URLComponents can trap, so refuse it first.
        guard APIPath.isValidEncodedPath(combined) else { throw Self.invalidPath }
        components.percentEncodedPath = combined
        // Drop empty values here (rather than requiring every call site to
        // filter its own dict) so a caller can pass e.g. an empty search
        // field straight through without special-casing "no filter." Keys are
        // sorted so the request URL is deterministic.
        let items = query.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw Self.invalidPath }
        return url
    }

    private static let invalidPath = APIError(statusCode: -1, code: "invalid_path", message: "The request path is not valid.")

    private func perform<B: Encodable>(
        path: String,
        method: String,
        body: B?,
        query: [String: String],
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw APIError(
                statusCode: -1,
                code: "insecure_transport",
                message: "The saved server address must use HTTPS. Re-enroll this server to continue."
            )
        }
        let url = try requestURL(path: path, query: query)
        let requestCredential = await credentialProvider?()
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token = requestCredential?.accessToken ?? fixedAccessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.iso8601.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(statusCode: -1, message: "Not an HTTP response", requestIdentity: requestCredential?.identity)
        }
        guard (200...299).contains(http.statusCode) else {
            let serverError = try? JSONDecoder.iso8601.decode(ServerErrorBody.self, from: data)
            let error = APIError(
                statusCode: http.statusCode,
                code: serverError?.code,
                message: serverError?.message ?? String(localized: "The server returned an error"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                requestIdentity: requestCredential?.identity,
                latestSequence: http.statusCode == 409
                    ? http.value(forHTTPHeaderField: "X-Silo-Latest-Sequence").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                    : nil,
                reason: serverError?.reason,
                capability: serverError?.capability
            )
            guard error.isClientUpgradeRequired else { throw error }
            throw APIError(
                statusCode: error.statusCode,
                code: error.code,
                message: String(localized: "This server needs a newer version of Bloem Admin."),
                retryAfter: error.retryAfter,
                requestIdentity: error.requestIdentity
            )
        }
        return (data, http)
    }
}

struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}

/// Two error shapes arrive: Bloem-native `{"error","message","code"?}` (also the
/// 410 tombstone) and v2 problem+json `{"type","title","status","detail"}`. For
/// problem+json the code is the last path segment of `type`; `about:blank` has none.
private struct ServerErrorBody: Decodable {
    private struct Detail: Decodable {
        let code: String?
        let message: String
    }

    let code: String?
    let message: String
    /// Bloem-native refusals name the protected person's class (`reason`) or the missing delivery (`capability`).
    /// Read leniently: a body where either is something other than a string still yields its code and message.
    var reason: String?
    var capability: String?

    private enum CodingKeys: String, CodingKey {
        case error, code, message, type, title, detail, reason, capability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        capability = (try? container.decodeIfPresent(String.self, forKey: .capability)) ?? nil
        if let type = try container.decodeIfPresent(String.self, forKey: .type) {
            code = Self.problemCode(from: type)
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            guard let text = [detail, title].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .detail, in: container, debugDescription: "Problem has no detail or title"
                )
            }
            message = text
            return
        }
        if let detail = try? container.decode(Detail.self, forKey: .error) {
            code = detail.code
            message = detail.message
            return
        }
        code = try container.decodeIfPresent(String.self, forKey: .code)
            ?? container.decodeIfPresent(String.self, forKey: .error)
        message = try container.decode(String.self, forKey: .message)
    }

    private static func problemCode(from type: String) -> String? {
        guard type != "about:blank" else { return nil }
        return type.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        // v2 instants carry milliseconds ("...:00.250Z"), which the stock `.iso8601` strategy rejects.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(text)"))
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
