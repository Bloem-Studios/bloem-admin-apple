import XCTest
@testable import BloemAdmin

/// From what the open app read per server to what the snapshot is told.
final class SnapshotCountsMapperTests: XCTestCase {
    private func server(_ id: String) -> AdminServer { .fixture(id) }

    func testASuccessSetsCountsAndAFailureClearsThem() {
        let results: [ServerSectionResult<SnapshotCounts>] = [
            ServerSectionResult(server: server("a"), result: .success(SnapshotCounts(streams: 2, requests: 3))),
            ServerSectionResult(
                server: server("b"),
                result: .failure(.signedOut(message: "Not signed in.", requestIdentity: nil))
            ),
        ]
        XCTAssertEqual(
            SnapshotCountsMapper.updates(from: results),
            ["a": .set(SnapshotCounts(streams: 2, requests: 3)), "b": .clear]
        )
    }

    func testServerInfoCarriesNameAndOnlyAnHTTPSOrigin() {
        let secure = AdminServer.fixture("a", name: "Home", host: "home.example.test:8443")
        XCTAssertEqual(
            secure.snapshotInfo,
            SnapshotServerInfo(id: "a", name: "Home", origin: URL(string: "https://home.example.test:8443"))
        )
        let plain = AdminServer(id: "b", baseURL: URL(string: "http://old.example.test")!, displayName: "Old")
        XCTAssertNil(plain.snapshotInfo.origin)
    }
}
