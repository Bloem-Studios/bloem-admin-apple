import Foundation

/// Tells a Bloem server from a plain Silo server, once per server and session.
///
/// The app works with every Silo server. What Bloem adds (organizations, platform administration, support access,
/// everything under `/api/bloem/`) is switched on only for a server that answers `GET /api/bloem/v2/capabilities`.
/// That route is public and always answers `200` on a Bloem server. A plain Silo server answers `404`, and so does
/// an unrelated server, so the answer is: 200 with a capabilities document means Bloem, 404 (or an answer that is
/// not a capabilities document, such as a proxy's HTML page) means plain Silo.
///
/// The answer is remembered for the session, per server address, so a plain Silo server is asked once and not on every
/// page, sign-in change or app start. A failure that says nothing about the server (no connection, a timeout, a
/// 5xx) is thrown and not remembered: the next ask tries again, and the caller keeps the Bloem extras off meanwhile.
///
/// One detector belongs to one `ServerStore`, which hands it to the clients it builds. A client built on its own
/// (`APIClient(baseURL:accessToken:)`, as the sign-in probes do) has none and asks the server every time.
final class BloemServerDetector: @unchecked Sendable {
    /// What a server answered: its capabilities (a Bloem server) or nothing (a plain Silo server).
    enum Verdict: Equatable, Sendable {
        case bloem(BloemCapabilities)
        case plainSilo

        var isBloem: Bool {
            if case .bloem = self { return true }
            return false
        }
    }

    private let lock = NSLock()
    private var verdicts: [String: Verdict] = [:]
    private var inFlight: [String: Task<Verdict, Error>] = [:]

    init() {}

    /// The remembered answer for a server address, without asking.
    func cachedVerdict(for origin: URL) -> Verdict? {
        lock.withLock { verdicts[Self.key(origin)] }
    }

    /// Whether any of these server addresses is remembered as a Bloem server.
    func anyKnownBloem(in origins: [URL]) -> Bool {
        origins.contains { cachedVerdict(for: $0)?.isBloem == true }
    }

    /// Forgets a server address, for a server that was removed.
    func forget(origin: URL) {
        let key = Self.key(origin)
        lock.withLock {
            verdicts[key] = nil
            inFlight[key] = nil
        }
    }

    private enum Step {
        case known(Verdict)
        case asking(Task<Verdict, Error>)
    }

    /// The remembered answer, the question already on its way, or a new question.
    private func begin(key: String, client: APIClient) -> Step {
        lock.withLock {
            if let known = verdicts[key] { return .known(known) }
            if let running = inFlight[key] { return .asking(running) }
            let task = Task { try await Self.probe(client) }
            inFlight[key] = task
            return .asking(task)
        }
    }

    private func finish(key: String, task: Task<Verdict, Error>, verdict: Verdict?) {
        lock.withLock {
            if inFlight[key] == task { inFlight[key] = nil }
            if let verdict { verdicts[key] = verdict }
        }
    }

    /// The server's verdict: remembered, or asked once even when several pages ask at the same moment.
    /// Throws what could not be decided (not remembered).
    func verdict(for client: APIClient) async throws -> Verdict {
        let key = Self.key(client.origin)
        switch begin(key: key, client: client) {
        case .known(let verdict):
            return verdict
        case .asking(let task):
            do {
                let verdict = try await task.value
                finish(key: key, task: task, verdict: verdict)
                return verdict
            } catch {
                finish(key: key, task: task, verdict: nil)
                throw error
            }
        }
    }

    /// One request, no remembering.
    static func probe(_ client: APIClient) async throws -> Verdict {
        do {
            return .bloem(try await client.bloemCapabilities())
        } catch let error as APIError where error.statusCode == 404 {
            return .plainSilo
        } catch is DecodingError {
            // A 200 that is not a capabilities document: something else answers for /api/bloem/ here.
            return .plainSilo
        }
    }

    private static func key(_ origin: URL) -> String {
        origin.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension APIClient {
    /// This server's Bloem capabilities, or nil when it is a plain Silo server. Remembered through the client's
    /// detector when it has one. Throws when the server could not be asked.
    func bloemCapabilitiesIfBloem() async throws -> BloemCapabilities? {
        let verdict: BloemServerDetector.Verdict
        if let detector = bloemDetector {
            verdict = try await detector.verdict(for: self)
        } else {
            verdict = try await BloemServerDetector.probe(self)
        }
        if case .bloem(let capabilities) = verdict { return capabilities }
        return nil
    }

    /// Whether this is a Bloem server. A server that could not be asked counts as not Bloem for now: the extras stay
    /// off and the next ask tries again.
    func isBloemServer() async -> Bool {
        (try? await bloemCapabilitiesIfBloem()) != nil
    }
}
