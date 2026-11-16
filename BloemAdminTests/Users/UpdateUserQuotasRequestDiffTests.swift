import XCTest
@testable import BloemAdmin

/// Review finding I4: the "only send changed fields" diffing logic
/// previously lived inline in `EditUserQuotasView.buildDiffedRequest()`
/// with zero test coverage — the one existing test
/// (`UsersViewModelTests.testUpdateQuotasSendsOnlyProvidedFields`) only
/// proved the JSON encoder omits `nil` fields, never that the diff itself
/// correctly decides what counts as "changed." The diff logic is now a
/// pure, SwiftUI-free function (`UpdateUserQuotasRequest.diff(from:to:)`
/// operating on `EditedUserQuotas`), exercised directly here.
@MainActor
final class UpdateUserQuotasRequestDiffTests: XCTestCase {
    private func makeUser(
        maxStreams: Int? = 3, maxTranscodes: Int? = 2, maxProfiles: Int? = 5,
        downloadAllowed: Bool? = true, requestsAllowed: Bool? = false,
        transcodeAllowed: Bool? = true, audioTranscodeAllowed: Bool? = false
    ) -> AdminUser {
        AdminUser(
            id: "1", username: "alex", email: "alex@example.test", role: "user", enabled: true,
            maxStreams: maxStreams, maxTranscodes: maxTranscodes,
            downloadAllowed: downloadAllowed, requestsAllowed: requestsAllowed,
            transcodeAllowed: transcodeAllowed, audioTranscodeAllowed: audioTranscodeAllowed,
            maxProfiles: maxProfiles
        )
    }

    func testUnmodifiedFormProducesEmptyDiff() {
        let user = makeUser()
        let edited = EditedUserQuotas.initial(from: user)

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertTrue(request.isEmpty)
    }

    func testChangedNumericFieldSendsItsNewValueOnly() {
        let user = makeUser()
        var edited = EditedUserQuotas.initial(from: user)
        edited.maxStreamsText = "7"

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertEqual(request.maxStreams, 7)
        XCTAssertNil(request.maxTranscodes)
        XCTAssertNil(request.maxProfiles)
        XCTAssertNil(request.downloadAllowed)
        XCTAssertNil(request.requestsAllowed)
        XCTAssertNil(request.transcodeAllowed)
        XCTAssertNil(request.audioTranscodeAllowed)
    }

    func testUnchangedNumericFieldSendsNothingEvenIfTextEqualsOriginal() {
        let user = makeUser(maxStreams: 3)
        var edited = EditedUserQuotas.initial(from: user)
        // Redundant "edit" back to the same value — must still omit it.
        edited.maxStreamsText = "3"

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertNil(request.maxStreams)
    }

    func testChangedPermissionSendsItsNewValueOnly() {
        let user = makeUser()
        var edited = EditedUserQuotas.initial(from: user)
        XCTAssertEqual(edited.requestsAllowed, .off) // sanity: matches makeUser's false
        edited.requestsAllowed = .on

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertEqual(request.requestsAllowed, true)
        XCTAssertNil(request.downloadAllowed)
        XCTAssertNil(request.transcodeAllowed)
        XCTAssertNil(request.audioTranscodeAllowed)
        XCTAssertNil(request.maxStreams)
    }

    func testUnchangedPermissionSendsNothing() {
        let user = makeUser(downloadAllowed: true)
        let edited = EditedUserQuotas.initial(from: user)
        XCTAssertEqual(edited.downloadAllowed, .on)

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertNil(request.downloadAllowed)
    }

    /// Review finding I3: a permission the server never reported starts as
    /// `.inherit`, not `.off` — diffing the untouched initial state against
    /// the original `nil` must produce no change (there's no way to
    /// "confirm unknown" as a value to send).
    func testUnknownPermissionLeftUntouchedSendsNothing() {
        let user = makeUser(downloadAllowed: nil)
        let edited = EditedUserQuotas.initial(from: user)
        XCTAssertEqual(edited.downloadAllowed, .inherit)

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertNil(request.downloadAllowed)
    }

    /// Explicitly resolving an unknown permission to Off/On must send that
    /// value — the admin is making a deliberate, informed choice, not
    /// having a default silently applied on their behalf.
    func testUnknownPermissionExplicitlySetSendsTheChosenValue() {
        let user = makeUser(downloadAllowed: nil)
        var edited = EditedUserQuotas.initial(from: user)
        edited.downloadAllowed = .on

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertEqual(request.downloadAllowed, true)
    }

    // MARK: - Non-numeric input (must not crash or misbehave)

    func testNonNumericTextInAQuotaFieldSendsNothingForThatFieldRatherThanCrashing() {
        let user = makeUser(maxStreams: 3)
        var edited = EditedUserQuotas.initial(from: user)
        edited.maxStreamsText = "not-a-number"

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertNil(request.maxStreams)
        XCTAssertTrue(request.isEmpty)
    }

    func testEmptyTextInAQuotaFieldSendsNothing() {
        let user = makeUser(maxStreams: 3)
        var edited = EditedUserQuotas.initial(from: user)
        edited.maxStreamsText = ""

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertNil(request.maxStreams)
    }

    func testMultipleChangedFieldsAllAppearTogether() {
        let user = makeUser()
        var edited = EditedUserQuotas.initial(from: user)
        edited.maxStreamsText = "10"
        edited.maxProfilesText = "1"
        edited.audioTranscodeAllowed = .on

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertEqual(request.maxStreams, 10)
        XCTAssertEqual(request.maxProfiles, 1)
        XCTAssertEqual(request.audioTranscodeAllowed, true)
        XCTAssertNil(request.maxTranscodes)
        XCTAssertNil(request.downloadAllowed)
        XCTAssertNil(request.requestsAllowed)
        XCTAssertNil(request.transcodeAllowed)
    }

    func testInheritedFieldsDisplayResolvedEffectiveValuesWithoutSendingChanges() {
        let user = AdminUser(
            id: "1",
            username: "alex",
            email: "alex@example.test",
            role: "user",
            enabled: true,
            maxStreams: nil,
            maxTranscodes: nil,
            downloadAllowed: nil,
            requestsAllowed: nil,
            transcodeAllowed: nil,
            audioTranscodeAllowed: nil,
            maxProfiles: 5,
            effectivePolicy: EffectivePolicy(
                libraryIDs: ["1"],
                maxPlaybackQuality: "1080p",
                maxStreams: 8,
                maxProfiles: 5,
                maxTranscodes: 4,
                transcodeAllowed: true,
                audioTranscodeAllowed: true,
                downloadAllowed: true,
                downloadTranscodeAllowed: false,
                requestsAllowed: false,
                permissions: []
            )
        )

        let edited = EditedUserQuotas.initial(from: user)
        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)

        XCTAssertTrue(edited.maxStreamsInherited)
        XCTAssertEqual(edited.maxStreamsText, "8")
        XCTAssertTrue(edited.maxTranscodesInherited)
        XCTAssertEqual(edited.maxTranscodesText, "4")
        XCTAssertEqual(edited.downloadAllowed, .inherit)
        XCTAssertEqual(edited.downloadAllowed.displayLabel(effectiveValue: user.effectivePolicy?.downloadAllowed), "Inherit (On)")
        XCTAssertTrue(request.isEmpty)
    }

    func testChangingStoredOverridesToInheritanceEncodesExplicitNulls() throws {
        let user = makeUser(maxStreams: 3, downloadAllowed: false)
        var edited = EditedUserQuotas.initial(from: user)
        edited.maxStreamsInherited = true
        edited.downloadAllowed = .inherit

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["max_streams", "download_allowed"])
        XCTAssertTrue(object["max_streams"] is NSNull)
        XCTAssertTrue(object["download_allowed"] is NSNull)
    }

    func testLeavingInheritedFieldsInheritedOmitsThemFromPayload() throws {
        let user = makeUser(maxStreams: nil, downloadAllowed: nil)
        let edited = EditedUserQuotas.initial(from: user)

        let request = UpdateUserQuotasRequest.diff(from: user, to: edited)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(object.isEmpty)
    }
}
