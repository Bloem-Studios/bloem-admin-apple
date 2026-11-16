import XCTest
@testable import BloemAdmin

/// An organization's plan: what it is on now, choosing another, the preview in plain words, and applying exactly what
/// was previewed.
@MainActor
final class PlatformPlanModelTests: XCTestCase {
    typealias F = PlatformFixtures

    private let baseURL = URL(string: "https://example.test")!
    private var entitlementPath: String { "\(F.base)/\(F.orgID)/entitlement" }
    private let previewTime = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!

    private func model(_ http: MockHTTPHarness, now: Date? = nil, key: String = "key-1") -> PlatformPlanModel {
        let account = APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)
        let clock = now ?? previewTime
        return PlatformPlanModel(
            organizationID: F.orgID, organizationName: "Riverside Club",
            pass: PlatformPass(account: account, baseURL: baseURL, session: http.session),
            now: { clock }, makeIdempotencyKey: { key }
        )
    }

    private func harness(current: String? = nil, key: String = "family") -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: F.mint, data: F.data(F.platformPass()))
        http.state.stub(path: entitlementPath, data: F.data(F.entitlement(key: key, group: current ?? F.policy(screens: 2))))
        http.state.stub(path: F.templates, data: F.data(F.templateList(
            F.template(key: "family", name: "Family", revision: 3, policy: F.policy(screens: 2)),
            F.template(key: "premium", name: "Premium", revision: 2, policy: F.policy(screens: 4))
        )))
        return http
    }

    // MARK: Showing the plan

    func testTheCurrentPlanIsNamedAndPreselected() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.currentPlanText, "Family, revision 3")
        XCTAssertEqual(model.selectedKey, "family")
        XCTAssertEqual(model.plans.map(\.name), ["Family", "Premium"])
        XCTAssertEqual(model.limitsText, "8 screens · 2 conversions at once")
        XCTAssertEqual(model.currentSettings.first { $0.label == "Screens at once" }?.value, "2 screens")
        XCTAssertNil(model.failure)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(http.state.requests(path: F.templates).first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "enabled")
    }

    func testAnOrganizationWithNoPlanSaysSoAndSelectsNothing() async throws {
        let http = harness(key: "")
        defer { http.invalidate() }
        http.state.stub(path: entitlementPath, data: F.data(F.entitlement(key: "", revision: 0, reconciled: nil)))
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.currentPlanText, "No plan yet")
        XCTAssertEqual(model.selectedKey, "")
        XCTAssertFalse(model.canPreview)
        XCTAssertTrue(model.currentSettings.isEmpty)
    }

    func testAPlanThatIsNoLongerOfferedIsFlaggedButKept() async throws {
        let http = harness(key: "legacy")
        defer { http.invalidate() }
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertTrue(model.currentPlanUnavailable)
        XCTAssertEqual(model.currentPlanText, "legacy, revision 3")
        XCTAssertEqual(model.selectedKey, "")
    }

    func testNoPlansOfferedIsSaidSo() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: F.templates, data: F.data(F.templateList()))
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertTrue(model.hasNoPlans)
    }

    func testALoadThatFailsKeepsTheKindAndRetryRecovers() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: entitlementPath, responses: [
            MockHTTPResponse(data: F.data(F.error("entitlements_unavailable", message: "Entitlement administration is unavailable")), status: 503),
            MockHTTPResponse(data: F.data(F.entitlement(group: F.policy(screens: 2)))),
        ])
        let model = model(http)

        await model.load(sessionState: nil)
        XCTAssertEqual(model.failure?.kind, .serverFailure)

        await model.load(sessionState: nil)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.currentPlanText, "Family, revision 3")
    }

    // MARK: Previewing

    func testPreviewingSendsTheChosenPlanAndSaysWhatChangesInPlainWords() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun(policy: F.policy(screens: 4, downloads: true))))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.preview(sessionState: nil)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(entitlementPath)/dry-run", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(body["template_key"] as? String, "premium")
        XCTAssertEqual(body["template_revision"] as? Int, 2)
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.headline, "Family, revision 3 → Premium, revision 2")
        XCTAssertEqual(confirmation.changes.map(\.sentence), [
            "Screens at once goes from 2 screens to 4 screens",
            "Download original files goes from No to Yes",
        ])
        XCTAssertTrue(model.canApply)
    }

    func testAPlanChangeStatesWhoItReachesAndWhoItDoesNot() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun()))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.preview(sessionState: nil)

        XCTAssertEqual(
            model.confirmation?.reach,
            "Members on the default settings get these changes. Access groups Riverside Club made itself stay as they are."
        )
    }

    func testPreviewingThePlanItAlreadyUsesSaysNothingChanges() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun(key: "family", revision: 3, changed: false, policy: F.policy(screens: 2))))
        let model = model(http)
        await model.load(sessionState: nil)

        await model.preview(sessionState: nil)

        XCTAssertEqual(model.previewNote, "Nothing changes: Riverside Club already uses this plan")
        XCTAssertFalse(model.canApply)
    }

    func testAnOrganizationWithNoPlanYetListsEverySettingAsNew() async throws {
        let http = harness(key: "")
        defer { http.invalidate() }
        http.state.stub(path: entitlementPath, data: F.data(F.entitlement(key: "", revision: 0, reconciled: nil)))
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun(previousKey: "", previousRevision: 0)))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.preview(sessionState: nil)

        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.headline, "No plan yet → Premium, revision 2")
        XCTAssertTrue(confirmation.changes.allSatisfy { $0.before == nil })
        XCTAssertEqual(confirmation.changes.first { $0.label == "Screens at once" }?.sentence, "Screens at once becomes 4 screens")
    }

    func testChoosingAnotherPlanThrowsAwayThePreview() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun()))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"
        await model.preview(sessionState: nil)
        XCTAssertNotNil(model.confirmation)

        model.selectedKey = "family"

        XCTAssertNil(model.confirmation)
        XCTAssertFalse(model.canApply)
    }

    func testAPreviewPastItsExpiryCannotBeApplied() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun()))
        let late = ISO8601DateFormatter().date(from: "2026-11-13T12:10:01Z")!
        let model = model(http, now: late)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.preview(sessionState: nil)

        XCTAssertTrue(model.previewExpired)
        XCTAssertFalse(model.canApply)
    }

    func testAPreviewThatFailsSaysSoAndKeepsTheChoice() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.error("template_unavailable", message: "Entitlement template revision is unavailable")), status: 422)
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.preview(sessionState: nil)

        XCTAssertEqual(model.actionError, "Entitlement template revision is unavailable")
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.selectedKey, "premium")
    }

    // MARK: Applying

    private func previewed(_ http: MockHTTPHarness) async -> PlatformPlanModel {
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun()))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"
        await model.preview(sessionState: nil)
        return model
    }

    func testApplyingSendsWhatWasPreviewedWithItsTokenAndKeyThenShowsTheNewPlan() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = await previewed(http)
        http.state.stub(path: "\(entitlementPath)/apply", data: F.data(F.applied()))
        http.state.stub(path: entitlementPath, data: F.data(F.entitlement(key: "premium", revision: 2, group: F.policy(screens: 4))))

        await model.apply(sessionState: nil)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(entitlementPath)/apply", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(body["template_key"] as? String, "premium")
        XCTAssertEqual(body["template_revision"] as? Int, 2)
        XCTAssertEqual(body["dry_run_token"] as? String, "dry.run.token")
        XCTAssertEqual(body["idempotency_key"] as? String, "key-1")
        XCTAssertEqual(model.currentPlanText, "Premium, revision 2")
        XCTAssertEqual(model.notice, "Riverside Club is now on Premium")
        XCTAssertNil(model.confirmation)
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.isApplying)
    }

    func testApplyingIsNotOfferedBeforeAPreview() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"

        await model.apply(sessionState: nil)

        XCTAssertTrue(http.state.requests(path: "\(entitlementPath)/apply").isEmpty)
    }

    func testAChangeThatMovedSincePreviewAsksForANewPreviewAndIsNotRepeated() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = await previewed(http)
        http.state.stub(path: "\(entitlementPath)/apply", data: F.data(F.error("confirmation_stale", message: "Entitlement state changed; dry-run again")), status: 409)

        await model.apply(sessionState: nil)

        XCTAssertEqual(http.state.requests(path: "\(entitlementPath)/apply").count, 1)
        XCTAssertEqual(model.actionError, "The plan changed since the preview. Preview again to see what it does now.")
        XCTAssertNil(model.confirmation, "the old preview cannot be applied")
        XCTAssertEqual(model.selectedKey, "premium")
    }

    func testAStalePassDuringApplyRenewsAndAsksForANewPreview() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.mint, responses: [
            MockHTTPResponse(data: F.data(F.platformPass("pass-1"))), MockHTTPResponse(data: F.data(F.platformPass("pass-2"))),
        ])
        http.state.stub(path: entitlementPath, data: F.data(F.entitlement(group: F.policy(screens: 2))))
        http.state.stub(path: F.templates, data: F.data(F.templateList(F.template(key: "family", name: "Family", revision: 3), F.template(key: "premium", name: "Premium", revision: 2))))
        http.state.stub(path: "\(entitlementPath)/dry-run", data: F.data(F.dryRun()))
        let model = model(http)
        await model.load(sessionState: nil)
        model.selectedKey = "premium"
        await model.preview(sessionState: nil)
        http.state.stub(path: "\(entitlementPath)/apply", data: F.data(F.error("tenant_session_required")), status: 401)

        await model.apply(sessionState: nil)

        XCTAssertEqual(http.state.requests(path: "\(entitlementPath)/apply").count, 1)
        XCTAssertEqual(model.actionError, "Your administrator access was renewed. Preview the change again to apply it.")
        XCTAssertNil(model.confirmation)
    }

    func testAnApplyTheServerRefusesIsShownInItsWordsAndThePreviewStays() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = await previewed(http)
        http.state.stub(path: "\(entitlementPath)/apply", data: F.data(F.error("entitlements_unavailable", message: "Entitlement administration is unavailable")), status: 503)

        await model.apply(sessionState: nil)

        XCTAssertEqual(model.actionError, "Entitlement administration is unavailable")
        XCTAssertNotNil(model.confirmation, "the same preview can be applied again once the server is back")
        XCTAssertNil(model.notice)
    }
}
