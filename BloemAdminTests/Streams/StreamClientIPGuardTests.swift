import XCTest

/// Client addresses are for the platform administrator only and never shown in an organization
/// context. The row's `showClientIP` defaults to false; only the platform pages switch it on. This
/// keeps a new page (an organization page, the dashboard preview) from turning it on by copying a call.
final class StreamClientIPGuardTests: XCTestCase {
    /// The platform pages: a single server's pages (the tab shell's `AdminGateView`, or the web-style
    /// shell's `SingleServerPages`) and All Servers.
    private let platformPages: Set<String> = [
        "Servers/AdminGateView.swift", "Servers/SingleServerPages.swift", "Servers/AllServersView.swift",
    ]

    private func lines(containing fragment: String) throws -> [(path: String, line: String)] {
        try SourceTree.appSources().flatMap { file in
            file.lines.filter { $0.contains(fragment) }.map { (file.path, $0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    func testOnlyThePlatformPagesShowClientAddresses() throws {
        let callers = try lines(containing: "showClientIP: true")
        let offenders = callers.filter { !platformPages.contains($0.path) }.map { "\($0.path): \($0.line)" }
        XCTAssertEqual(offenders, [], "showClientIP: true outside the platform pages")
        // The scan itself works, and All Servers and at least one single-server page still ask for it.
        let pages = Set(callers.map(\.path))
        XCTAssertTrue(pages.contains("Servers/AllServersView.swift"), "All Servers no longer passes showClientIP: true")
        XCTAssertGreaterThanOrEqual(pages.count, 2, "no single-server page passes showClientIP: true: \(pages)")
    }

    func testTheFlagDefaultsToOffEverywhere() throws {
        let defaults = try lines(containing: "showClientIP = true") + lines(containing: "showClientIP: Bool = true")
        XCTAssertEqual(defaults.map { "\($0.path): \($0.line)" }, [], "showClientIP must default to false")
        XCTAssertFalse(try lines(containing: "showClientIP: Bool = false").isEmpty, "the row's default is no longer found")
    }
}
