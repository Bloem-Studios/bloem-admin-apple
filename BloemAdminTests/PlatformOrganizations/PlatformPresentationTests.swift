import XCTest
@testable import BloemAdmin

/// The words the Organizations pages use, which follow the web's (components/admin/policy/policyVocabulary.ts and the
/// platformOrganizations strings): a status in words, a role, what suspending does to people, and a plan change said
/// setting by setting.
final class PlatformPresentationTests: XCTestCase {
    // MARK: Status, role and counts

    func testAnOrganizationStatusIsSaidInWords() {
        XCTAssertEqual(PlatformOrganizationText.status("active"), "Active")
        XCTAssertEqual(PlatformOrganizationText.status("suspended"), "Suspended")
        XCTAssertEqual(PlatformOrganizationText.status("initializing"), "Setting up")
        XCTAssertEqual(PlatformOrganizationText.status("archived"), "Archived", "an unknown status is shown, capitalised, never hidden")
    }

    func testTheStatusFilterAsksTheServerForExactlyWhatItNames() {
        XCTAssertNil(PlatformOrganizationStatusFilter.all.serverValue)
        XCTAssertEqual(PlatformOrganizationStatusFilter.active.serverValue, "active")
        XCTAssertEqual(PlatformOrganizationStatusFilter.suspended.serverValue, "suspended")
        XCTAssertEqual(PlatformOrganizationStatusFilter.settingUp.serverValue, "initializing")
        XCTAssertEqual(PlatformOrganizationStatusFilter.allCases.map(\.title), ["Any status", "Active", "Suspended", "Setting up"])
    }

    func testAMemberIsOwnerAdministratorOrMember() {
        let owner = PlatformMembership(id: "m1", accountID: 4, status: "active", legacyRole: "admin")
        let admin = PlatformMembership(id: "m2", accountID: 5, status: "active", legacyRole: "admin")
        let member = PlatformMembership(id: "m3", accountID: 6, status: "active", legacyRole: "user")
        XCTAssertEqual(PlatformOrganizationText.role(of: owner, ownerAccountID: 4), "Owner")
        XCTAssertEqual(PlatformOrganizationText.role(of: admin, ownerAccountID: 4), "Administrator")
        XCTAssertEqual(PlatformOrganizationText.role(of: member, ownerAccountID: 4), "Member")
        XCTAssertEqual(PlatformOrganizationText.role(of: member, ownerAccountID: nil), "Member")
    }

    func testAMembershipStatusIsSaidInWords() {
        XCTAssertEqual(PlatformOrganizationText.membershipStatus("active"), "Active")
        XCTAssertEqual(PlatformOrganizationText.membershipStatus("suspended"), "Suspended")
        XCTAssertEqual(PlatformOrganizationText.membershipStatus("invited"), "Invited")
    }

    func testARowSaysHowManyPeopleProfilesAndLibraries() throws {
        let one = try JSONDecoder().decode(OrganizationSummary.self, from: Data(PlatformFixtures.organization(members: 1, profiles: 1, libraries: 1).utf8))
        let many = try JSONDecoder().decode(OrganizationSummary.self, from: Data(PlatformFixtures.organization(members: 12, profiles: 25, libraries: 3).utf8))
        XCTAssertEqual(PlatformOrganizationText.counts(one), "1 person · 1 profile · 1 library")
        XCTAssertEqual(PlatformOrganizationText.counts(many), "12 people · 25 profiles · 3 libraries")
    }

    // MARK: What suspending and reactivating mean for people

    func testSuspendingSaysHowManyActiveMembersLoseAccessAndThatNothingIsDeleted() {
        XCTAssertEqual(
            PlatformOrganizationText.suspendConsequence(name: "Riverside Club", activeMembers: 10),
            "10 active members lose access to Riverside Club until you reactivate it. Nothing is deleted."
        )
        XCTAssertEqual(
            PlatformOrganizationText.suspendConsequence(name: "Riverside Club", activeMembers: 1),
            "1 active member loses access to Riverside Club until you reactivate it. Nothing is deleted."
        )
        XCTAssertEqual(
            PlatformOrganizationText.suspendConsequence(name: "Riverside Club", activeMembers: 0),
            "Nobody is active in Riverside Club right now. Anyone who joins loses access until you reactivate it. Nothing is deleted."
        )
    }

    func testReactivatingSaysTheMembersCanUseItAgain() {
        XCTAssertEqual(
            PlatformOrganizationText.reactivateConsequence(name: "Riverside Club"),
            "Members of Riverside Club can use it again."
        )
    }

    // MARK: Settings in words

    func testALimitIsCountedAndZeroMeansNoLimit() {
        XCTAssertEqual(PolicyWords.limit(0, .screens), "No limit")
        XCTAssertEqual(PolicyWords.limit(1, .screens), "1 screen")
        XCTAssertEqual(PolicyWords.limit(4, .screens), "4 screens")
        XCTAssertEqual(PolicyWords.limit(1, .profiles), "1 profile")
        XCTAssertEqual(PolicyWords.limit(3, .conversions), "3 conversions")
    }

    func testQualityLibrariesAndPermissionsReadAsThePersonWouldSayThem() {
        XCTAssertEqual(PolicyWords.quality(""), "Any quality")
        XCTAssertEqual(PolicyWords.quality("original"), "Original quality")
        XCTAssertEqual(PolicyWords.quality("1080p"), "Up to 1080p")
        XCTAssertEqual(PolicyWords.quality("2160p"), "Up to 4K")
        XCTAssertEqual(PolicyWords.quality("720p"), "720p")
        XCTAssertEqual(PolicyWords.libraries(nil), "All libraries")
        XCTAssertEqual(PolicyWords.libraries([]), "None")
        XCTAssertEqual(PolicyWords.libraries([3, 5]), "Library 3, Library 5")
        XCTAssertEqual(PolicyWords.permissions(nil), "All permissions")
        XCTAssertEqual(PolicyWords.permissions([]), "None")
        XCTAssertEqual(PolicyWords.permissions(["metadata_curation", "watch_live_tv", "marker_edit"]), "Edit metadata, Watch Live TV, Edit intro and credits markers")
        XCTAssertEqual(PolicyWords.permissions(["some_new_permission"]), "Some new permission", "an unknown permission is humanised, not dropped")
    }

    func testASettingsListNamesEveryRowTheWebShows() {
        let rows = PolicyWords.rows(EntitlementPolicy(maxStreams: 2, maxProfiles: 5, maxTranscodes: 1, maxPlaybackQuality: "1080p"))
        XCTAssertEqual(rows.map(\.label), [
            "Libraries", "Plays video", "Screens at once", "Profiles", "Video conversion", "Conversions at once",
            "Download original files", "Download converted copies", "Best picture quality", "Media requests", "Extra permissions",
        ])
        XCTAssertEqual(rows.first { $0.label == "Screens at once" }?.value, "2 screens")
        XCTAssertEqual(rows.first { $0.label == "Video conversion" }?.value, "Yes")
        XCTAssertEqual(rows.first { $0.label == "Download original files" }?.value, "No")
    }

    // MARK: A plan change in plain words

    private func policy(screens: Int = 2, downloads: Bool = false, quality: String = "1080p", libraries: [Int]? = nil) -> EntitlementPolicy {
        EntitlementPolicy(libraryIDs: libraries, maxStreams: screens, maxProfiles: 5, maxTranscodes: 1, downloadAllowed: downloads, maxPlaybackQuality: quality)
    }

    func testOnlyTheSettingsThatChangeAreListedWithTheirOldAndNewValues() {
        let changes = PlanChangeSummary.changes(from: policy(screens: 2, downloads: false), to: policy(screens: 4, downloads: true))
        XCTAssertEqual(changes.map(\.label), ["Screens at once", "Download original files"])
        XCTAssertEqual(changes.map(\.before), ["2 screens", "No"])
        XCTAssertEqual(changes.map(\.after), ["4 screens", "Yes"])
    }

    func testEachChangeIsASentence() {
        let changes = PlanChangeSummary.changes(from: policy(screens: 2), to: policy(screens: 4))
        XCTAssertEqual(changes.map(\.sentence), ["Screens at once goes from 2 screens to 4 screens"])
    }

    func testAMovedLibrarySetIsAChange() {
        let changes = PlanChangeSummary.changes(from: policy(libraries: [1]), to: policy(libraries: nil))
        XCTAssertEqual(changes.map(\.sentence), ["Libraries goes from Library 1 to All libraries"])
    }

    func testWithNoSettingsYetEveryOneIsNew() {
        let changes = PlanChangeSummary.changes(from: nil, to: policy(screens: 4))
        XCTAssertEqual(changes.count, PolicyWords.rows(policy()).count)
        XCTAssertEqual(changes.first { $0.label == "Screens at once" }?.sentence, "Screens at once becomes 4 screens")
        XCTAssertTrue(changes.allSatisfy { $0.before == nil })
    }

    func testTheSamePolicyHasNothingToChange() {
        XCTAssertTrue(PlanChangeSummary.changes(from: policy(), to: policy()).isEmpty)
    }

    func testThePlanNamesAreInTheHeadlineWithTheirRevision() {
        XCTAssertEqual(
            PlanChangeSummary.headline(from: "Family", fromRevision: 3, to: "Premium", toRevision: 2),
            "Family, revision 3 → Premium, revision 2"
        )
        XCTAssertEqual(
            PlanChangeSummary.headline(from: nil, fromRevision: 0, to: "Premium", toRevision: 2),
            "No plan yet → Premium, revision 2"
        )
    }
}
