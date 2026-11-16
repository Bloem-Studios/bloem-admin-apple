import XCTest
@testable import BloemAdmin

final class AccessPolicyTests: XCTestCase {
    private let family = AccessGroup(id: "g1", name: "Family", libraryIDs: ["1", "2"], allowedPermissions: ["marker_edit"])
    private let open = AccessGroup(id: "g2", name: "Open", libraryIDs: nil, allowedPermissions: nil)
    private var groups: [AccessGroup] { [family, open] }

    private func user(role: String = "user", group: String? = nil, libraries: [String]? = nil, permissions: [String] = []) -> AdminUser {
        AdminUser(
            id: "2", username: "bob", email: "bob@example.test", role: role, enabled: true,
            maxStreams: nil, maxTranscodes: nil, accessGroupID: group, libraryIDs: libraries, permissions: permissions
        )
    }

    private func json(_ request: UpdateUserQuotasRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Locks and inheritance labels

    func testAGroupThatDoesNotListAPermissionLocksIt() {
        XCTAssertEqual(
            AccessPolicy.permissionLock(role: "user", groupID: "g1", groups: groups, permission: "watch_live_tv"),
            PermissionLock(locked: true, groupName: "Family")
        )
        XCTAssertEqual(
            AccessPolicy.permissionLock(role: "user", groupID: "g1", groups: groups, permission: "marker_edit"),
            PermissionLock(locked: false, groupName: "Family")
        )
    }

    func testAGroupThatAllowsEverythingNoGroupAnAdminAndAnUnknownGroupLockNothing() {
        func locked(_ role: String, _ group: String?) -> Bool {
            AccessPolicy.permissionLock(role: role, groupID: group, groups: groups, permission: "watch_live_tv").locked
        }
        XCTAssertFalse(locked("user", "g2"))
        XCTAssertFalse(locked("user", nil))
        XCTAssertFalse(locked("admin", "g1"))
        XCTAssertFalse(locked("user", "gone"))
    }

    func testInheritedLibrariesFollowTheGroupPickedInTheForm() {
        let defaults = UserPolicyDefaults(admin: PolicyDefaultsHint(libraryIDs: nil), ungrouped: PolicyDefaultsHint(libraryIDs: ["9"]))
        func inherited(role: String = "user", draft: String?, saved: String?, inheritsNow: Bool, effective: [String]?) -> InheritedLibraries {
            AccessPolicy.inheritedLibraries(
                role: role, draftGroupID: draft, savedGroupID: saved, inheritsNow: inheritsNow,
                effectiveLibraryIDs: effective, groups: groups, defaults: defaults
            )
        }
        // Saved without a group and inheriting: the server's own resolved list.
        XCTAssertEqual(inherited(draft: nil, saved: nil, inheritsNow: true, effective: ["9"]), .some(["9"]))
        // Picking a group changes what inherit means, before anything is saved.
        XCTAssertEqual(inherited(draft: "g1", saved: nil, inheritsNow: true, effective: ["9"]), .some(["1", "2"]))
        XCTAssertEqual(inherited(draft: "g2", saved: nil, inheritsNow: true, effective: ["9"]), .all)
        // Picking no group again falls back to the ungrouped defaults when the account overrides now.
        XCTAssertEqual(inherited(draft: nil, saved: "g1", inheritsNow: false, effective: ["1"]), .some(["9"]))
        XCTAssertEqual(inherited(role: "admin", draft: "g1", saved: nil, inheritsNow: false, effective: nil), .all)
    }

    func testAnInheritLabelIsNotInventedWhileItsSourceIsUnknown() {
        func inherited(draft: String?, groups: [AccessGroup]?, defaults: UserPolicyDefaults?) -> InheritedLibraries {
            AccessPolicy.inheritedLibraries(
                role: "user", draftGroupID: draft, savedGroupID: nil, inheritsNow: false,
                effectiveLibraryIDs: nil, groups: groups, defaults: defaults
            )
        }
        XCTAssertEqual(inherited(draft: "g1", groups: nil, defaults: nil), .unknown)
        XCTAssertEqual(inherited(draft: "gone", groups: groups, defaults: nil), .unknown)
        XCTAssertEqual(inherited(draft: nil, groups: groups, defaults: nil), .unknown)
        XCTAssertTrue(AccessPolicy.inheritsFromGroup(role: "user", draftGroupID: "g1"))
        XCTAssertFalse(AccessPolicy.inheritsFromGroup(role: "user", draftGroupID: nil))
        XCTAssertFalse(AccessPolicy.inheritsFromGroup(role: "admin", draftGroupID: "g1"))
    }

    func testLibrariesAreToggledInTheOrderTheServerListsThem() {
        let all = ["1", "2", "3"]
        XCTAssertEqual(AccessPolicy.toggleLibrary(selected: ["3"], all: all, id: "1", on: true), ["1", "3"])
        XCTAssertEqual(AccessPolicy.toggleLibrary(selected: ["1", "3"], all: all, id: "1", on: false), ["3"])
    }

    func testAGroupNameFallsBackToItsIDWhileTheListLacksIt() {
        XCTAssertEqual(AccessPolicy.groupName("g1", in: groups), "Family")
        XCTAssertEqual(AccessPolicy.groupName("zz", in: groups), "#zz")
    }

    // MARK: - The save body

    func testAnUnchangedFormSendsNothing() {
        let u = user(group: "g1", libraries: ["1"], permissions: ["marker_edit"])
        let draft = UserAccessDraft.initial(from: u)
        XCTAssertTrue(draft.request(against: u).isEmpty)
        XCTAssertFalse(draft.isDirty(against: u))
        // The same libraries and permissions in another order are still unchanged.
        var reordered = draft
        reordered.access = UserAccessEdit(groupID: "g1", libraryIDs: ["1"], permissions: ["marker_edit"])
        XCTAssertTrue(reordered.request(against: u).isEmpty)
    }

    func testChangingTheGroupSendsItAndNoGroupClearsIt() throws {
        let u = user(group: "g1")
        var draft = UserAccessDraft.initial(from: u)
        draft.access.groupID = "g2"
        XCTAssertEqual(draft.request(against: u).accessGroupID, .set("g2"))
        XCTAssertEqual(try json(draft.request(against: u))["access_group_id"] as? String, "g2")

        draft.access.groupID = nil
        XCTAssertEqual(draft.request(against: u).accessGroupID, .clear)
        let body = try json(draft.request(against: u))
        XCTAssertEqual(Set(body.keys), ["access_group_id"])
        XCTAssertTrue(body["access_group_id"] is NSNull)
    }

    func testAnAdminsGroupIsNeverSent() {
        let admin = user(role: "admin")
        var draft = UserAccessDraft.initial(from: admin)
        draft.access.groupID = "g1"
        XCTAssertTrue(draft.request(against: admin).isEmpty)
    }

    func testLibrariesInheritWithNullChooseWithAListAndMayBeChosenEmpty() throws {
        let inheriting = user()
        var draft = UserAccessDraft.initial(from: inheriting)
        draft.access.libraryIDs = ["3", "1"]
        XCTAssertEqual(try json(draft.request(against: inheriting))["library_ids"] as? [String], ["1", "3"])

        draft.access.libraryIDs = []
        XCTAssertEqual(try json(draft.request(against: inheriting))["library_ids"] as? [String], [])

        let own = user(libraries: ["1"])
        var back = UserAccessDraft.initial(from: own)
        back.access.libraryIDs = nil
        XCTAssertTrue(try json(back.request(against: own))["library_ids"] is NSNull)
    }

    func testPermissionsAreSentAsTheWholeAssignedSet() throws {
        let u = user(permissions: ["marker_edit"])
        var added = UserAccessDraft.initial(from: u)
        added.access.permissions = AccessPolicy.setAssignedPermission(u.permissions, "watch_live_tv", on: true)
        XCTAssertEqual(try json(added.request(against: u))["permissions"] as? [String], ["marker_edit", "watch_live_tv"])

        var cleared = UserAccessDraft.initial(from: u)
        cleared.access.permissions = AccessPolicy.setAssignedPermission(u.permissions, "marker_edit", on: false)
        XCTAssertEqual(try json(cleared.request(against: u))["permissions"] as? [String], [])
    }

    func testLimitsAndAccessTravelInOneBody() throws {
        let u = user(group: "g1")
        var draft = UserAccessDraft.initial(from: u)
        draft.limits.maxStreamsInherited = false
        draft.limits.maxStreamsText = "4"
        draft.access.groupID = "g2"
        let body = try json(draft.request(against: u))
        XCTAssertEqual(Set(body.keys), ["max_streams", "access_group_id"])
        XCTAssertEqual(body["max_streams"] as? Int, 4)
        XCTAssertEqual(body["access_group_id"] as? String, "g2")
    }

    func testAnInvalidLimitIsNotSavable() {
        let u = user()
        var draft = UserAccessDraft.initial(from: u)
        draft.limits.maxStreamsInherited = false
        draft.limits.maxStreamsText = ""
        draft.access.groupID = "g1"
        XCTAssertTrue(draft.hasInvalidValue)
        XCTAssertFalse(draft.isDirty(against: u), "a form with a bad number is not dirty enough to save")
    }

    func testMaxProfilesCanRestoreInheritanceWithAnExplicitNull() throws {
        let u = AdminUser(id: "2", username: "bob", email: "b@example.test", role: "user", enabled: true, maxStreams: nil, maxTranscodes: nil, maxProfiles: 4)
        var draft = UserAccessDraft.initial(from: u)
        draft.limits.maxProfilesInherited = true
        let body = try json(draft.request(against: u))
        XCTAssertEqual(Set(body.keys), ["max_profiles"])
        XCTAssertTrue(body["max_profiles"] is NSNull)
    }
}
