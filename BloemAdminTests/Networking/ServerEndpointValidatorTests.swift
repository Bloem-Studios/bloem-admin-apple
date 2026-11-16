import XCTest
@testable import BloemAdmin

final class ServerEndpointValidatorTests: XCTestCase {
    func testCanonicalizesSupportedHTTPSOrigins() throws {
        let cases: [(input: String, expected: String)] = [
            ("https://media.example.test", "https://media.example.test"),
            ("  https://media.example.test  ", "https://media.example.test"),
            ("https://MEDIA.EXAMPLE.TEST:443", "https://media.example.test"),
            ("https://media.example.test/", "https://media.example.test"),
            ("https://media.example.test:8443", "https://media.example.test:8443"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                try ServerEndpointValidator.validate(testCase.input).absoluteString,
                testCase.expected,
                "input: \(testCase.input)"
            )
        }
    }

    func testRejectsValuesThatAreNotHTTPSOrigins() {
        let invalidValues = [
            "http://media.example.test",
            "https:///api/v1/health",
            "https://admin:secret@media.example.test",
            "https://media.example.test?tenant=one",
            "https://media.example.test#status",
            "https://media.example.test/admin",
        ]

        for value in invalidValues {
            XCTAssertThrowsError(
                try ServerEndpointValidator.validate(value),
                "unexpectedly accepted: \(value)"
            )
        }
    }

    func testTypedAddressWithoutASchemeAssumesHTTPS() throws {
        XCTAssertEqual(try ServerEndpointValidator.validateTyped("media.example.test").absoluteString, "https://media.example.test")
        XCTAssertEqual(try ServerEndpointValidator.validateTyped("  Media.Example.Test:8443/ ").absoluteString, "https://media.example.test:8443")
        XCTAssertEqual(try ServerEndpointValidator.validateTyped("HTTPS://media.example.test").absoluteString, "https://media.example.test")
    }

    func testTypedAddressKeepsEveryOtherRule() {
        let cases: [(String, ServerEndpointValidationError)] = [
            ("", .empty),
            ("   ", .empty),
            ("http://media.example.test", .requiresHTTPS),
            ("ftp://media.example.test", .requiresHTTPS),
            ("media.example.test/admin", .pathNotAllowed),
            ("admin:secret@media.example.test", .userInfoNotAllowed),
            ("media.example.test?tenant=one", .queryNotAllowed),
            ("media.example.test#status", .fragmentNotAllowed),
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try ServerEndpointValidator.validateTyped(input), input) { error in
                XCTAssertEqual(error as? ServerEndpointValidationError, expected, input)
            }
        }
    }

    func testFinishedAddressesNeedAHostWithALetteredTopLevelLabel() {
        for input in ["media.example.test", "Example.Test", "example.test:8443", "https://example.test", " example.test "] {
            XCTAssertTrue(ServerEndpointValidator.isFinishedAddress(input), input)
        }
        for input in ["", "example", "example.t", "example.test.", "localhost", "10.0.0.5", "[::1]",
                      "http://example.test", "example.test/admin", "user@example.test"] {
            XCTAssertFalse(ServerEndpointValidator.isFinishedAddress(input), input)
        }
    }

    func testAcceptsExplicitPortBoundaries() throws {
        XCTAssertEqual(
            try ServerEndpointValidator.validate("https://media.example.test:1").absoluteString,
            "https://media.example.test:1"
        )
        XCTAssertEqual(
            try ServerEndpointValidator.validate("https://media.example.test:65535").absoluteString,
            "https://media.example.test:65535"
        )
    }

    func testRejectsExplicitPortsOutsideTCPRange() {
        XCTAssertThrowsError(try ServerEndpointValidator.validate("https://media.example.test:0"))
        XCTAssertThrowsError(try ServerEndpointValidator.validate("https://media.example.test:65536"))
    }
}
