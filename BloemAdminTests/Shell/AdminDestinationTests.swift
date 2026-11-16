import UIKit
import XCTest
@testable import BloemAdmin

final class AdminDestinationTests: XCTestCase {
    func testGroupsFollowTheWebAdminOrder() {
        XCTAssertEqual(
            AdminGroup.allCases.filter { $0 != .organization },
            [.platform, .monitor, .manage, .configure]
        )
        XCTAssertEqual(
            AdminGroup.allCases.map { String(localized: $0.label) },
            ["Platform", "Monitor", "Manage", "Configure", "Organization"]
        )
        XCTAssertEqual(String(localized: AdminGroup.platform.label), "Platform")
    }

    func testSingleServerMenuFollowsTheWebGroupsAndNames() {
        let menu = AdminDestination.singleServer(tenantsVisible: false)
        XCTAssertEqual(
            AdminDestination.menuOrder(menu).map { "\($0.group):\($0.labelText)" },
            [
                "monitor:Dashboard", "monitor:Now playing", "monitor:Logs", "monitor:Audit",
                "manage:Libraries", "manage:Requests", "manage:Users", "manage:Playback history", "manage:Nodes",
                "configure:Server settings", "configure:Scheduled tasks", "configure:Backups", "configure:API keys", "configure:Plugins",
            ]
        )
        XCTAssertEqual(
            AdminDestination.menuOrder(menu).map(\.id),
            ["overview.dashboard", "live.streams", "system.logs", "system.audit", "content.libraries", "work.requests",
             "people.users", "live.activity", "playback.nodes", "system.server", "work.jobs", "system.backups",
             "system.api-keys", "system.plugins"]
        )
    }

    func testAGroupWithNoPagesIsLeftOutOfTheMenu() {
        let plain = AdminDestination.grouped(AdminDestination.singleServer(tenantsVisible: false))
        XCTAssertEqual(plain.map(\.group), [.monitor, .manage, .configure], "no Platform group without its pages")
        let owner = AdminDestination.grouped(AdminDestination.singleServer(tenantsVisible: false, supportAccessVisible: true))
        XCTAssertEqual(owner.map(\.group), [.platform, .monitor, .manage, .configure])
        XCTAssertEqual(owner.first?.pages.map(\.labelText), ["Support access"])
    }

    func testOrganizationsAndSupportAccessLeadThePlatformGroup() {
        let shown = AdminDestination.singleServer(tenantsVisible: true, supportAccessVisible: true)
        let platform = AdminDestination.grouped(shown).first
        XCTAssertEqual(platform?.group, .platform)
        XCTAssertEqual(platform?.pages.map(\.id), ["platform.organizations", "platform.support-access"])
    }

    func testOrganizationsAppearOnlyWhenTenantsAreVisible() {
        let hidden = AdminDestination.singleServer(tenantsVisible: false).map(\.id)
        let shown = AdminDestination.singleServer(tenantsVisible: true).map(\.id)
        XCTAssertFalse(hidden.contains("platform.organizations"))
        XCTAssertEqual(shown, ["platform.organizations"] + hidden, "Platform leads the menu")
        XCTAssertEqual(AdminDestination.singleServer(tenantsVisible: true).first { $0.id == "platform.organizations" }?.group, .platform)
        XCTAssertEqual(AdminDestination.organizations.labelText, "Organizations")
        XCTAssertFalse(AdminDestination.singleServer(tenantsVisible: false).contains { $0.id == "platform.organizations" })
    }

    func testThePlatformGroupHoldsOrganizationsThenSupportAccessAndLeadsTheMenu() {
        let sections = AdminDestination.grouped(AdminDestination.singleServer(tenantsVisible: true, supportAccessVisible: true))
        XCTAssertEqual(sections.first?.group, .platform)
        XCTAssertEqual(sections.first?.pages.map(\.id), ["platform.organizations", "platform.support-access"])
        XCTAssertEqual(AdminDestination.menuOrder(AdminDestination.singleServer(tenantsVisible: true)).first?.id, "platform.organizations")
        // Without either, the group is left out and the menu opens as before.
        XCTAssertEqual(AdminDestination.grouped(AdminDestination.singleServer(tenantsVisible: false)).first?.group, .monitor)
        // All servers has Organizations (a section per server) but not Support access, which is for one organization.
        let allServers = AdminDestination.grouped(AdminDestination.allServers)
        XCTAssertEqual(allServers.first?.group, .platform)
        XCTAssertEqual(allServers.first?.pages.map(\.id), ["platform.organizations"])
    }

    func testOrganizationsCarryTheWebsDescriptionAndSearchWords() {
        XCTAssertEqual(AdminDestination.organizations.descriptionText, "Every organization on this server, and its members")
        XCTAssertEqual(AdminDestination.organizations.keywords, ["organizations", "tenants", "memberships"])
    }

    func testAllServersMenuIsTheSubsetWithoutLogsOrSupportAccess() {
        let menu = AdminDestination.allServers
        XCTAssertEqual(
            AdminDestination.menuOrder(menu).map(\.id),
            ["platform.organizations", "overview.dashboard", "live.streams", "system.audit", "content.libraries", "work.requests",
             "people.users", "live.activity", "playback.nodes", "system.server", "work.jobs", "system.backups", "system.plugins"]
        )
        XCTAssertFalse(menu.contains { $0.id == "system.logs" || $0.id == "platform.support-access" })
    }

    func testAServerAndAllServersOpenOnNowPlaying() {
        XCTAssertEqual(AdminDestination.startID, "live.streams")
        XCTAssertEqual(AdminDestination.nowPlaying.labelText, "Now playing")
        XCTAssertEqual(AdminDestination.effective(selectedID: nil, in: AdminDestination.allServers)?.id, "live.streams")
        XCTAssertEqual(
            AdminDestination.effective(selectedID: nil, in: AdminDestination.singleServer(tenantsVisible: false))?.id,
            "live.streams"
        )
        // Platform leads the All servers menu.
        XCTAssertEqual(AdminDestination.menuOrder(AdminDestination.allServers).first?.id, "platform.organizations")
    }

    func testAnUnknownSelectionFallsBackToNowPlaying() {
        let withoutLogs = AdminDestination.allServers
        XCTAssertEqual(AdminDestination.effective(selectedID: "system.logs", in: withoutLogs)?.id, "live.streams")
        XCTAssertEqual(AdminDestination.effective(selectedID: "live.activity", in: withoutLogs)?.id, "live.activity")
        XCTAssertNil(AdminDestination.effective(selectedID: nil, in: []))
    }

    func testGroupedKeepsGroupOrderAndSkipsEmptyGroups() {
        let grouped = AdminDestination.grouped(AdminDestination.allServers)
        XCTAssertEqual(grouped.map(\.group), [.platform, .monitor, .manage, .configure])
        XCTAssertEqual(
            AdminDestination.grouped(AdminDestination.allServers.filter { $0.group <= .monitor }).map(\.group),
            [.platform, .monitor]
        )
        // A shuffled input still lists groups in menu order, pages in the order given.
        let shuffled = Array(AdminDestination.allServers.reversed())
        XCTAssertEqual(AdminDestination.grouped(shuffled).map(\.group), [.platform, .monitor, .manage, .configure])
        XCTAssertEqual(AdminDestination.grouped(shuffled).dropFirst().first?.pages.map(\.id), ["system.audit", "live.streams", "overview.dashboard"])
    }

    // MARK: Swipe

    func testSwipeWalksTheMenuInOrderWithoutWrapping() {
        let menu = AdminDestination.singleServer(tenantsVisible: false)
        var id: String? = "overview.dashboard"
        var visited = [id!]
        while let next = AdminDestination.adjacent(to: id, step: 1, in: menu) {
            id = next.id
            visited.append(next.id)
        }
        XCTAssertEqual(visited, AdminDestination.menuOrder(menu).map(\.id))
        XCTAssertEqual(visited.last, "system.plugins")
        XCTAssertNil(AdminDestination.adjacent(to: "system.plugins", step: 1, in: menu), "no wrap past the last page")
        XCTAssertEqual(AdminDestination.adjacent(to: "system.logs", step: 1, in: menu)?.id, "system.audit", "Audit follows Logs")
        XCTAssertNil(AdminDestination.adjacent(to: "overview.dashboard", step: -1, in: menu), "no wrap before the first page")
        XCTAssertEqual(AdminDestination.adjacent(to: "work.jobs", step: -1, in: menu)?.id, "system.server")
        XCTAssertNil(AdminDestination.adjacent(to: "unknown", step: 1, in: menu))
        XCTAssertNil(AdminDestination.adjacent(to: nil, step: 1, in: menu))
    }

    func testSwipeOrderSkipsPagesThatAreNotInTheMenu() {
        // All servers has no Logs: Now playing is followed by Audit.
        XCTAssertEqual(AdminDestination.adjacent(to: "live.streams", step: 1, in: AdminDestination.allServers)?.id, "system.audit")
        XCTAssertEqual(
            AdminDestination.adjacent(to: "live.streams", step: 1, in: AdminDestination.singleServer(tenantsVisible: false))?.id,
            "system.logs"
        )
        XCTAssertEqual(AdminDestination.adjacent(to: "content.libraries", step: 1, in: AdminDestination.allServers)?.id, "work.requests")
    }

    func testSwipeDirectionAndThreshold() {
        // Left is next, right is previous.
        XCTAssertEqual(PageSwipe.step(forTranslation: -120, height: 4), 1)
        XCTAssertEqual(PageSwipe.step(forTranslation: 120, height: -4), -1)
        // Too short.
        XCTAssertEqual(PageSwipe.step(forTranslation: -40, height: 0), 0)
        XCTAssertEqual(PageSwipe.step(forTranslation: PageSwipe.distance - 1, height: 0), 0)
        XCTAssertEqual(PageSwipe.step(forTranslation: -PageSwipe.distance, height: 0), 1)
        // Mostly vertical: scrolling, not a swipe.
        XCTAssertEqual(PageSwipe.step(forTranslation: -80, height: 90), 0)
        XCTAssertEqual(PageSwipe.step(forTranslation: -80, height: 60), 0)
        XCTAssertEqual(PageSwipe.step(forTranslation: -80, height: 40), 1)
    }

    // MARK: Icons and text

    func testEveryPageHasItsOwnIconTheWebsDescriptionAndKeywords() {
        for menu in [AdminDestination.singleServer(tenantsVisible: true), AdminDestination.allServers] {
            XCTAssertEqual(Set(menu.map(\.icon)).count, menu.count, "icons are distinct within a menu")
            for page in menu {
                XCTAssertFalse(page.descriptionText.isEmpty, "\(page.id) has a description")
                XCTAssertFalse(page.keywords.isEmpty, "\(page.id) has keywords")
                XCTAssertNotNil(UIImage(named: page.icon.assetName), "\(page.id) uses a Lucide icon that is in the catalog: \(page.icon.rawValue)")
            }
        }
        let single = Dictionary(uniqueKeysWithValues: AdminDestination.singleServer(tenantsVisible: true).map { ($0.id, $0.icon) })
        for page in AdminDestination.allServers {
            XCTAssertEqual(single[page.id], page.icon, "the same page has the same icon in the All servers menu")
        }
    }

    func testPagesCarryTheWebNamesAndDescriptions() {
        let byID = Dictionary(uniqueKeysWithValues: AdminDestination.singleServer(tenantsVisible: true).map { ($0.id, $0) })
        XCTAssertEqual(byID["live.streams"]?.descriptionText, "Live streams and current playback sessions")
        XCTAssertEqual(byID["live.activity"]?.labelText, "Playback history")
        XCTAssertEqual(byID["work.jobs"]?.labelText, "Scheduled tasks")
        XCTAssertEqual(byID["system.server"]?.labelText, "Server settings")
        XCTAssertEqual(byID["system.audit"]?.descriptionText, "Who changed what on this server, and when")
        XCTAssertEqual(byID["playback.nodes"]?.labelText, "Nodes")
        XCTAssertEqual(byID["playback.nodes"]?.descriptionText, "Stream nodes, remote worker status, and where playback work runs")
        XCTAssertEqual(byID["system.backups"]?.labelText, "Backups")
        XCTAssertEqual(byID["system.backups"]?.descriptionText, "Nightly backups of the database and uploaded files, and how to restore them")
        XCTAssertEqual(byID["system.plugins"]?.labelText, "Plugins")
        XCTAssertEqual(byID["system.plugins"]?.descriptionText, "Plugin catalog, repositories, installs, and plugin configuration")
    }

    func testNodesBackupsAndPluginsAreNotInTheOrganizationMenu() {
        let organizationIDs = OrganizationPage.allCases.map { AdminDestination.organization($0).id }
        for id in ["playback.nodes", "system.backups", "system.plugins"] {
            XCTAssertFalse(organizationIDs.contains(id))
        }
    }

    func testNodesBackupsAndPluginsHaveTheWebsKeywords() {
        XCTAssertTrue(AdminDestination.nodes.keywords.contains("transcode nodes"))
        XCTAssertTrue(AdminDestination.backups.keywords.contains("pg_dump"))
        XCTAssertTrue(AdminDestination.plugins.keywords.contains("plugin catalog"))
    }

    // MARK: Libraries

    func testLibrariesLeadsTheManageGroupBeforeRequestsInBothMenus() {
        for menu in [AdminDestination.singleServer(tenantsVisible: false), AdminDestination.allServers] {
            let manage = menu.filter { $0.group == .manage }.map(\.id)
            XCTAssertEqual(Array(manage.prefix(2)), ["content.libraries", "work.requests"])
        }
        XCTAssertEqual(AdminDestination.libraries.labelText, "Libraries")
    }

    func testLibrariesCarriesTheWebsDescriptionAndKeywords() {
        XCTAssertEqual(AdminDestination.libraries.descriptionText, "Media libraries, paths, scanning, and catalog import")
        XCTAssertEqual(AdminDestination.libraries.keywords, ["library", "paths", "scan", "catalog", "seed", "libraries", "mount", "refresh metadata"])
    }

    func testOrganizationMenusHaveNoLibrariesPage() {
        for page in OrganizationPage.allCases {
            XCTAssertNotEqual(AdminDestination.organization(page).id, AdminDestination.libraries.id)
        }
    }
}
