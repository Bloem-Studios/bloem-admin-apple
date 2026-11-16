import XCTest

/// Keeps every API path in one place and keeps the app off the retired v1 routes.
final class APIPathGuardTests: XCTestCase {
    private func isApiFile(_ path: String) -> Bool {
        path.hasPrefix("Networking/API/") || path == "Networking/AuthAPI.swift"
    }

    func testApiPathLiteralsLiveOnlyInTheApiFiles() throws {
        var offenders: [String] = []
        for file in try SourceTree.appSources() where !isApiFile(file.path) {
            for (index, line) in file.lines.enumerated() where line.contains("\"/api/") {
                offenders.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "\"/api/ literals outside Networking/API/ and Networking/AuthAPI.swift")
    }

    func testNoV1PathExceptHealth() throws {
        var offenders: [String] = []
        for file in try SourceTree.appSources() {
            for (index, line) in file.lines.enumerated() {
                var rest = Substring(line)
                while let range = rest.range(of: "/api/v1/") {
                    let after = rest[range.upperBound...]
                    if !after.hasPrefix("health") {
                        offenders.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                        break
                    }
                    rest = after
                }
            }
        }
        XCTAssertEqual(offenders, [], "/api/v1/ paths other than /api/v1/health")
    }

    func testScannerSeesTheSources() throws {
        let paths = try SourceTree.appSources().map(\.path)
        XCTAssertTrue(paths.contains("Networking/AuthAPI.swift"))
        XCTAssertTrue(paths.contains("Networking/API/StatusAPI.swift"))
        XCTAssertGreaterThan(paths.count, 50)
    }
}
