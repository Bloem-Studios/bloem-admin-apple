import XCTest
@testable import BloemAdmin

final class PageSearchTests: XCTestCase {
    /// The text the app shows, spelled out so the tests do not depend on the simulator's language.
    private let pages: [SearchablePage] = AdminDestination.singleServer(tenantsVisible: true).map { destination in
        let (label, description): (String, String) = switch destination.id {
        case "overview.dashboard": ("Dashboard", "Live sessions, content health, and server activity")
        case "live.streams": ("Now playing", "Live streams and current playback sessions")
        case "live.activity": ("Playback history", "Historical playback events across users and profiles")
        case "system.logs": ("Logs", "Server log stream and operational output")
        case "content.libraries": ("Libraries", "Media libraries, paths, scanning, and catalog import")
        case "work.requests": ("Requests", "Review, approve, and decline media requests")
        case "work.jobs": ("Scheduled tasks", "Background task schedules, runs, and run history")
        case "people.users": ("Users", "Accounts, roles, profile settings, and access")
        case "platform.organizations": ("Organizations", "Every organization on this server, and its members")
        case "system.server": ("Server settings", "The server's name and public address, the proxies in front of it, and Redis")
        case "playback.nodes": ("Nodes", "Stream nodes, remote worker status, and where playback work runs")
        case "system.backups": ("Backups", "Nightly backups of the database and uploaded files, and how to restore them")
        case "system.plugins": ("Plugins", "Plugin catalog, repositories, installs, and plugin configuration")
        case "system.api-keys": ("API keys", "Admin API keys and tier assignment")
        default: ("Audit", "Who changed what on this server, and when")
        }
        let group: String = switch destination.group {
        case .platform: "Platform"
        case .monitor: "Monitor"
        case .manage: "Manage"
        case .configure: "Configure"
        case .organization: "Organization"
        }
        return SearchablePage(destination: destination, groupLabel: group, label: label, description: description)
    }

    private func ids(_ query: String) -> [String] {
        PageSearch.filter(pages, query: query).flatMap(\.pages).map(\.destination.id)
    }

    func testABlankQueryListsEveryPageInMenuOrder() {
        let expected = AdminDestination.menuOrder(pages.map(\.destination)).map(\.id)
        XCTAssertEqual(ids(""), expected)
        XCTAssertEqual(ids("   "), expected)
        XCTAssertEqual(ids("?!"), expected, "punctuation alone normalises to nothing")
    }

    func testMatchesOnLabelDescriptionAndKeywordsAsTheWebDoes() {
        XCTAssertEqual(ids("scheduled"), ["work.jobs"])
        // A keyword the label and description lack.
        XCTAssertEqual(ids("scheduler"), ["work.jobs"])
        XCTAssertEqual(ids("transcode"), ["live.streams", "playback.nodes"])
        // A word of the description.
        XCTAssertEqual(ids("approve"), ["work.requests"])
        XCTAssertEqual(ids("redis"), ["system.server"])
        XCTAssertEqual(ids("memberships"), ["platform.organizations"])
        XCTAssertEqual(ids("reverse proxy"), ["system.server"])
    }

    func testEveryWordMustMatchAndCaseAndAccentsDoNotMatter() {
        XCTAssertEqual(ids("DECLINE requests"), ["work.requests"])
        XCTAssertEqual(ids("Décline"), ["work.requests"])
        XCTAssertTrue(ids("decline jobs").isEmpty)
        XCTAssertTrue(ids("zzz").isEmpty)
    }

    func testAWordStartsWithTheTokenOrContainsItFromFourLetters() {
        // "ers" starts no word and is under four letters, so it matches nothing inside "users".
        XCTAssertFalse(ids("ers").contains("people.users"))
        // "file" (four letters) sits inside "profiles"; "ile" (three) does not.
        XCTAssertTrue(ids("file").contains("live.activity"))
        XCTAssertFalse(ids("ile").contains("live.activity"))
    }

    func testAGroupsNameKeepsAllItsPages() {
        XCTAssertEqual(ids("monitor"), ["overview.dashboard", "live.streams", "system.logs", "system.audit"])
        XCTAssertEqual(ids("manage"), ["content.libraries", "work.requests", "people.users", "live.activity", "playback.nodes"])
        XCTAssertEqual(ids("configure"), ["system.server", "work.jobs", "system.backups", "system.api-keys", "system.plugins"])
        XCTAssertEqual(ids("platform"), ["platform.organizations"])
        XCTAssertEqual(PageSearch.filter(pages, query: "monitor").map(\.group), [.monitor])
        // "Users" is a page, and a word in Playback history's description.
        XCTAssertEqual(Set(PageSearch.filter(pages, query: "users").flatMap(\.pages).map(\.id)), ["people.users", "live.activity"])
    }

    func testResultsStayGroupedInMenuOrder() {
        let groups = PageSearch.filter(pages, query: "live").map(\.group)
        XCTAssertEqual(groups, groups.sorted())
        XCTAssertFalse(groups.isEmpty)
    }

    func testOrganizationPagesAreFoundByTheirOwnKeywords() {
        let org = [
            AdminDestination(
                id: "organization.decisions", group: .organization, label: "Decisions", icon: .shieldCheck,
                pageDescription: "Why someone was allowed or refused something.", keywords: ["policy", "authorization", "denied"]
            ),
            AdminDestination(
                id: "organization.cohorts", group: .organization, label: "Cohorts", icon: .usersRound,
                pageDescription: "Groups of accounts that share the same settings.", keywords: ["entitlements", "revisions"]
            ),
        ].map { SearchablePage(destination: $0, groupLabel: "Organization", label: "Page", description: "") }
        XCTAssertEqual(PageSearch.filter(org, query: "denied").flatMap(\.pages).map(\.id), ["organization.decisions"])
        XCTAssertEqual(PageSearch.filter(org, query: "revisions").flatMap(\.pages).map(\.id), ["organization.cohorts"])
        XCTAssertEqual(PageSearch.filter(org, query: "organization").flatMap(\.pages).count, 2)
    }

    func testNormalisation() {
        XCTAssertEqual(PageSearch.normalize("  Déjà-Vu!  Plays "), "deja vu plays")
        XCTAssertEqual(PageSearch.normalize("A/B_c"), "a b c")
        XCTAssertEqual(PageSearch.tokens("  Scheduled   Tasks "), ["scheduled", "tasks"])
        XCTAssertEqual(PageSearch.tokens("..."), [])
    }
}
