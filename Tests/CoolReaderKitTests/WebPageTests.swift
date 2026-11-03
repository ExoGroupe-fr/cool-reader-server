import Foundation
import Testing
@testable import CoolReaderKit

/// The site's frame: the sidebar a member gets, and the icons its libraries take.
struct WebPageTests {
    private static let libraries = [
        LibraryRecord(id: 1, name: "Mangas", path: "/m", lastScanAt: nil, lastError: nil, seriesCount: 3, bookCount: 20),
        LibraryRecord(id: 2, name: "BD", path: "/b", lastScanAt: nil, lastError: nil, seriesCount: 1, bookCount: 6),
    ]

    private static func page(admin: Bool, section: String) -> String {
        let user = UserRecord(id: 1, name: "léa", isAdmin: admin, allLibraries: true, libraryIDs: [])
        var page = WebPage(title: "Accueil", strings: Strings("fr"), caller: Caller(user: user, device: nil), libraries: libraries,
                           section: section)
        page.add("<p>contenu</p>")
        return page.html
    }

    @Test func theSidebarListsTheLibrariesAndMarksTheCurrentOne() {
        let html = Self.page(admin: false, section: "/library/2")
        #expect(html.contains("href=\"/library/1\""))
        #expect(html.contains("<a href=\"/library/2\" aria-current=\"page\">"))
        #expect(!html.contains("<a href=\"/\" aria-current"))
        #expect(html.contains("<span class=\"who\">léa</span>") && html.contains(">L</span>"))
        // A member who isn't the admin sees no admin page.
        #expect(!html.contains("href=\"/members\"") && !html.contains("href=\"/server\""))
        #expect(html.contains("<p>contenu</p>"))
    }

    @Test func theAdminAlsoGetsTheAdminPages() {
        let html = Self.page(admin: true, section: "/members")
        #expect(html.contains("<a href=\"/members\" aria-current=\"page\">"))
        #expect(html.contains("href=\"/libraries\"") && html.contains("href=\"/devices\"") && html.contains("href=\"/server\""))
    }

    @Test func librariesTakeAnIconByWhatTheyHold() {
        #expect(Icon.library(named: "Mangas") == Icon.manga)
        #expect(Icon.library(named: "Mes BD") == Icon.comics)
        #expect(Icon.library(named: "Comics VO") == Icon.comics)
        #expect(Icon.library(named: "Romans") == Icon.novel)
        #expect(Icon.library(named: "Divers") == Icon.books)
    }
}
