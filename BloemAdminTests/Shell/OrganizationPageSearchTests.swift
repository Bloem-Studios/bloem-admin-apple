import XCTest
@testable import BloemAdmin

/// Page search in organization mode, as Android has it: the organization's pages are destinations of the
/// Organization group, found by the web's words, and picking one opens that page.
final class OrganizationPageSearchTests: XCTestCase {
    private func searchable(_ pages: [OrganizationPage]) -> [SearchablePage] {
        pages.map { page in
            let destination = AdminDestination.organization(page)
            return SearchablePage(
                destination: destination, groupLabel: "Organization", label: page.title,
                description: destination.descriptionText
            )
        }
    }

    private func ids(_ query: String, pages: [OrganizationPage] = OrganizationPage.allCases) -> [String] {
        PageSearch.filter(searchable(pages), query: query).flatMap(\.pages).map(\.destination.id)
    }

    func testEveryOrganizationPageIsADestinationOfTheOrganizationGroup() {
        let destinations = OrganizationPage.allCases.map(AdminDestination.organization)

        XCTAssertEqual(destinations.map(\.group), Array(repeating: .organization, count: OrganizationPage.allCases.count))
        XCTAssertEqual(destinations.map(\.id), OrganizationPage.allCases.map { "organization.\($0.rawValue)" })
        XCTAssertEqual(Set(destinations.map(\.id)).count, destinations.count)
        for destination in destinations {
            XCTAssertFalse(destination.descriptionText.isEmpty, destination.id)
            XCTAssertFalse(destination.keywords.isEmpty, destination.id)
            XCTAssertFalse(destination.descriptionText.hasSuffix("."), "\(destination.id): a caption has no trailing period")
        }
    }

    func testTheOrganizationDestinationsKeepTheMenusPageNamesAndIcons() {
        for page in OrganizationPage.allCases {
            let destination = AdminDestination.organization(page)
            XCTAssertEqual(destination.labelText, page.title)
            XCTAssertEqual(destination.icon, page.icon)
        }
    }

    func testTheIDsNeverOverlapThePlatformPages() {
        let platform = Set(AdminDestination.singleServer(tenantsVisible: true, supportAccessVisible: true).map(\.id))
        let organization = Set(OrganizationPage.allCases.map { AdminDestination.organization($0).id })

        XCTAssertTrue(platform.isDisjoint(with: organization))
    }

    func testADestinationMapsBackToItsPage() {
        for page in OrganizationPage.allCases {
            XCTAssertEqual(AdminDestination.organization(page).organizationPage, page)
        }
        XCTAssertNil(AdminDestination.dashboard.organizationPage)
    }

    func testSearchFindsAPageByTheWebsWords() {
        XCTAssertEqual(ids("invite"), ["organization.invitations"])
        XCTAssertEqual(ids("audit"), ["organization.activity"])
        XCTAssertEqual(ids("who changed"), ["organization.activity"])
        XCTAssertEqual(ids("permissions"), ["organization.groups"])
        XCTAssertEqual(ids("denied"), ["organization.decisions"])
        XCTAssertEqual(ids("memberships"), ["organization.people"])
        XCTAssertEqual(ids("media ceiling"), ["organization.libraries"])
        XCTAssertEqual(ids("now playing"), ["organization.streams"])
    }

    func testSearchByAWordTwoPagesShareFindsBoth() {
        XCTAssertEqual(Set(ids("entitlements")), ["organization.cohorts", "organization.libraries"])
        XCTAssertEqual(Set(ids("policy")), ["organization.cohorts", "organization.decisions"])
    }

    func testTheGroupNameListsEveryPageAndABlankQueryDoesToo() {
        let all = OrganizationPage.allCases.map { "organization.\($0.rawValue)" }
        XCTAssertEqual(ids("organization"), all)
        XCTAssertEqual(ids(""), all)
    }

    func testStreamsIsSearchableOnlyOnAServerThatOffersIt() {
        var without = SupportCapabilities.none
        without.streams.list = false
        var with = SupportCapabilities.none
        with.streams.list = true

        XCTAssertFalse(ids("streams", pages: OrganizationPage.offered(without)).contains("organization.streams"))
        XCTAssertTrue(ids("streams", pages: OrganizationPage.offered(with)).contains("organization.streams"))
    }

    func testNothingMatchingFindsNothing() {
        XCTAssertEqual(ids("tenants"), [], "platform words do not find organization pages")
        XCTAssertEqual(ids("zzzz"), [])
    }
}
