import Foundation
import NIOHTTP1
import Testing
@testable import CoolReaderKit

/// The admin's API for Cool Reader: refused to members, libraries, a member and their invitation, the server's
/// settings, and deleting a book, refused until it is allowed, then sent to the library's hidden trash.
struct AdminAPITests {
    @Test func theAdminRunsTheServerFromTheApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mangas = folder.appendingPathComponent("Mangas")
        try FileManager.default.createDirectory(at: mangas.appendingPathComponent("Akira"), withIntermediateDirectories: true)
        for volume in 1...2 {
            try TestZip.make([TestZip.File(name: "1.jpg", data: Data([1]))]).write(to: mangas.appendingPathComponent("Akira/Akira 0\(volume).cbz"))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("BD"), withIntermediateDirectories: true)
        var config = ServerConfig(configDirectory: folder.appendingPathComponent("config"))
        config.onlineMetadata = false
        config.systemTrash = false
        try FileManager.default.createDirectory(at: config.configDirectory, withIntermediateDirectories: true)
        let store = try Store(path: config.configDirectory.appendingPathComponent("library.sqlite").path)
        let library = try store.addLibrary(name: "Mangas", path: mangas.path)
        let admin = try #require(store.user(id: try store.createUser(name: "Alex", passwordHash: "", isAdmin: true, allLibraries: true, libraryIDs: [])))
        let reader = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: "", isAdmin: false, allLibraries: true, libraryIDs: [])))
        let context = try ServerContext(config: config, store: store)
        await context.scanner.scanNow(library)
        var router = Router()
        APIRoutes.add(to: &router, context: context)
        AdminAPIRoutes.add(to: &router, context: context)
        let token = try context.issueToken(for: admin, deviceName: "iPhone", kind: "app")
        let memberToken = try context.issueToken(for: reader, deviceName: "iPad", kind: "app")
        func call(_ path: String, _ method: HTTPMethod = .GET, _ body: String = "", as caller: String? = nil) async -> Response {
            await router.handle(ServerTests.request(path, method: method, token: caller ?? token, body: body))
        }

        #expect(await call("/api/v1/admin/libraries", as: memberToken).status == .forbidden)
        let libraries = try ServerTests.decode([AdminAPIRoutes.LibraryInfo].self, await call("/api/v1/admin/libraries"))
        #expect(libraries.map(\.name) == ["Mangas"] && libraries.first?.bookCount == 2)
        let added = try ServerTests.decode(AdminAPIRoutes.LibraryInfo.self,
                                           await call("/api/v1/admin/libraries", .POST, #"{"name": "BD", "path": "\#(folder.path)/BD"}"#))
        #expect(added.name == "BD")
        #expect(await call("/api/v1/admin/libraries", .POST, #"{"name": "X", "path": "/nowhere/at/all"}"#).status == .badRequest)

        let created = try ServerTests.decode(AdminAPIRoutes.NewMemberResult.self, await call(
            "/api/v1/admin/members", .POST, #"{"name": "Sam", "libraryIDs": [\#(library)]}"#))
        #expect(created.member.name == "Sam" && !created.member.hasPassword && created.member.libraryIDs == [library])
        #expect(created.invitation.link?.hasPrefix("coolreader://connect?") == true)
        let changed = try ServerTests.decode(AdminAPIRoutes.MemberInfo.self, await call(
            "/api/v1/admin/members/\(created.member.id)", .PATCH, #"{"allLibraries": true, "password": "a-good-password"}"#))
        #expect(changed.allLibraries && changed.hasPassword)
        #expect(await call("/api/v1/admin/members/\(admin.id)", .DELETE).status == .forbidden)
        let devices = try ServerTests.decode([AdminAPIRoutes.DeviceInfo].self, await call("/api/v1/admin/devices"))
        #expect(Set(devices.map(\.name)) == ["iPhone", "iPad"])

        let books = store.books(libraryID: library)
        #expect(await call("/api/v1/admin/books/\(books[0].id)", .DELETE).status == .forbidden)
        let settings = try ServerTests.decode(AdminAPIRoutes.ServerSettings.self, await call(
            "/api/v1/admin/server", .PATCH, #"{"name": "Le mini", "allowDeletion": true}"#))
        #expect(settings.name == "Le mini" && settings.allowDeletion && !settings.comicVineKeySet)
        #expect(await call("/api/v1/admin/books/\(books[0].id)", .DELETE).status == .ok)
        #expect(store.book(id: books[0].id) == nil)
        #expect(FileManager.default.fileExists(atPath: mangas.appendingPathComponent(".cool-reader-trash/\(books[0].path)").path))
        #expect(!FileManager.default.fileExists(atPath: mangas.appendingPathComponent(books[0].path).path))
        // The trash stays out of the library at the next scan.
        await context.scanner.scanNow(library)
        #expect(store.books(libraryID: library).map(\.id) == [books[1].id])
    }
}
