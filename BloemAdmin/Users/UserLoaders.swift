import Foundation
import Observation

/// One section's read: not yet read, read, or failed with the server's own message.
enum LoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// A read-only section of the User page that is read once, and again when the admin retries. A
/// failed re-read leaves the section already shown.
@Observable
@MainActor
final class SectionLoader<Value: Sendable> {
    private(set) var state: LoadState<Value> = .loading
    private let serverName: String?
    private let sessionState: ServerScopedSession?
    private let fallback: String
    private let fetch: @MainActor () async throws -> Value

    init(
        serverName: String? = nil,
        sessionState: ServerScopedSession? = nil,
        fallback: String = String(localized: "This section couldn't be loaded. Try again."),
        fetch: @escaping @MainActor () async throws -> Value
    ) {
        self.serverName = serverName
        self.sessionState = sessionState
        self.fallback = fallback
        self.fetch = fetch
    }

    func load() async {
        do {
            state = .loaded(try await fetch())
        } catch {
            if case .loaded = state { return }
            state = .failed(ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName))
        }
    }
}

/// A cursor-paged read-only list. `loadMore` appends the next page; a repeated cursor ends the list.
@Observable
@MainActor
final class PagedFeed<Item: Decodable & Sendable> {
    private(set) var items: [Item] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = false

    private var cursor: String?
    private var seen = Set<String>()
    private let serverName: String?
    private let sessionState: ServerScopedSession?
    private let fallback: String
    private let fetch: @MainActor (String?) async throws -> APICollection<Item>

    init(
        serverName: String? = nil,
        sessionState: ServerScopedSession? = nil,
        fallback: String = String(localized: "This section couldn't be loaded. Try again."),
        fetch: @escaping @MainActor (String?) async throws -> APICollection<Item>
    ) {
        self.serverName = serverName
        self.sessionState = sessionState
        self.fallback = fallback
        self.fetch = fetch
    }

    /// Reads the first page again and replaces the list.
    func reload() async { await read(first: true) }

    func loadMore() async {
        if hasMore { await read(first: false) }
    }

    private func read(first: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(first ? nil : cursor)
            items = first ? page.items : items + page.items
            if first { seen.removeAll() }
            let next = page.page.flatMap { $0.hasMore ? $0.nextCursor : nil }
            if let next {
                hasMore = seen.insert(next).inserted
            } else {
                hasMore = false
            }
            cursor = next
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
        }
    }
}

/// Formatting the User page shares: short watch times and decimal file sizes.
enum UserFormat {
    /// "2 h 5 min", "45 min", "30 s".
    static func watchTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(localized: "\(hours) h \(minutes) min") }
        if minutes > 0 { return String(localized: "\(minutes) min") }
        return String(localized: "\(total) s")
    }

    /// "1.5 GB"; decimal units, as the server reports them.
    static func bytes(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        let units = ["kB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }

    static func date(_ date: Date?) -> String? {
        date.map { $0.formatted(date: .abbreviated, time: .omitted) }
    }

    static func dateTime(_ date: Date?) -> String? {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) }
    }
}
