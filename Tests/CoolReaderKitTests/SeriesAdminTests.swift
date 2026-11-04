import Foundation
import NIOHTTP1
import Testing
@testable import CoolReaderKit

/// The admin's hand on a series, through the API: a title and a synopsis of their own, no metadata at all, and a
/// choice the matcher never overwrites. Offline: nothing is asked of the catalogues.
struct SeriesAdminTests {
    @Test func theAdminEditsASeriesAndMembersCant() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let akira = folder.appendingPathComponent("Mangas/Akira")
        try FileManager.default.createDirectory(at: akira, withIntermediateDirectories: true)
        try TestZip.make([TestZip.File(name: "1.jpg", data: Data([1]))]).write(to: akira.appendingPathComponent("Akira 01.cbz"))
        var config = ServerConfig(configDirectory: folder.appendingPathComponent("config"))
        config.onlineMetadata = false
        try FileManager.default.createDirectory(at: config.configDirectory, withIntermediateDirectories: true)
        let store = try Store(path: config.configDirectory.appendingPathComponent("library.sqlite").path)
        let library = try store.addLibrary(name: "Mangas", path: folder.appendingPathComponent("Mangas").path)
        let admin = try #require(store.user(id: try store.createUser(name: "Alex", passwordHash: "", isAdmin: true, allLibraries: true, libraryIDs: [])))
        let member = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: "", isAdmin: false, allLibraries: true, libraryIDs: [])))
        let context = try ServerContext(config: config, store: store)
        await context.scanner.scanNow(library)
        var router = Router()
        APIRoutes.add(to: &router, context: context)
        SeriesAdminRoutes.add(to: &router, context: context)
        let adminToken = try context.issueToken(for: admin, deviceName: "Test", kind: "app")
        let memberToken = try context.issueToken(for: member, deviceName: "Test", kind: "app")
        let series = try #require(store.series(libraryID: library).first)

        func edit(_ body: String, token: String) async -> Response {
            await router.handle(ServerTests.request("/api/v1/admin/series/\(series.id)", method: .PATCH, token: token, body: body))
        }
        #expect(await edit(#"{"title": "Akira, l'édition originale"}"#, token: memberToken).status == .forbidden)
        let edited = try ServerTests.decode(APIRoutes.SeriesDetail.self,
                                            await edit(#"{"title": "Akira, l'édition originale", "summary": "Neo-Tokyo, 2019."}"#, token: adminToken))
        #expect(edited.series.title == "Akira, l'édition originale" && edited.series.summary == "Neo-Tokyo, 2019.")
        // A field left out stays; an empty one gives the catalogues' back.
        let cleared = try ServerTests.decode(APIRoutes.SeriesDetail.self, await edit(#"{"title": ""}"#, token: adminToken))
        #expect(cleared.series.title == "Akira" && cleared.series.summary == "Neo-Tokyo, 2019.")

        let ignored = try ServerTests.decode(APIRoutes.SeriesDetail.self,
                                             await router.handle(ServerTests.request("/api/v1/admin/series/\(series.id)/unmatch", method: .POST,
                                                                                     token: adminToken)))
        #expect(ignored.series.matchStatus == "ignored")

        // The matcher's answer, come after the admin chose, leaves the admin's choice.
        var chosen = SeriesMatch(source: .anilist)
        chosen.title = "AKIRA"
        try store.setMatch(seriesID: series.id, status: "manual", match: chosen)
        try store.setMatch(seriesID: series.id, status: "matched", match: SeriesMatch(source: .appleBooks), onlyIfPending: true)
        #expect(store.series(id: series.id)?.matchStatus == "manual" && store.series(id: series.id)?.match?.source == .anilist)
    }
}
