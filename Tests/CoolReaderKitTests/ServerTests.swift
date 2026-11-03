import Foundation
import NIOHTTP1
import Testing
@testable import CoolReaderKit

struct ServerTests {
    /// PBKDF2-HMAC-SHA256 test vectors ("password", "salt").
    @Test func derivesPBKDF2Keys() {
        func hex(_ iterations: Int) -> String {
            Passwords.pbkdf2(password: Array("password".utf8), salt: Array("salt".utf8), iterations: iterations)
                .map { String(format: "%02x", $0) }.joined()
        }
        #expect(hex(1) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(hex(2) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(hex(4096) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    @Test func hashesPasswordsWithSalt() {
        let hash = Passwords.hash("correct horse", iterations: 1000)
        #expect(hash.hasPrefix("pbkdf2-sha256$1000$"))
        #expect(Passwords.verify("correct horse", hash: hash))
        #expect(!Passwords.verify("correct horses", hash: hash))
        #expect(hash != Passwords.hash("correct horse", iterations: 1000))
    }

    @Test func routesByPathAndMethod() async {
        var router = Router()
        router.add(.GET, "/series/:id") { request in .json(["id": request.parameters["id"] ?? ""]) }
        #expect(await router.handle(Self.request("/series/42")).status == .ok)
        #expect(await router.handle(Self.request("/series/42", method: .POST)).status == .methodNotAllowed)
        #expect(await router.handle(Self.request("/books/42")).status == .notFound)
    }

    /// A library scanned into series, served to the admin, refused to a member without it, read over OPDS.
    @Test func servesLibrariesToTheMembersWhoSeeThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mangas = folder.appendingPathComponent("library/Mangas"), comics = folder.appendingPathComponent("library/BD")
        for directory in [mangas.appendingPathComponent("Akira"), comics.appendingPathComponent("Blacksad"), folder.appendingPathComponent("config")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for volume in 1...2 {
            try TestZip.make([TestZip.File(name: "10.jpg", data: Data([10, UInt8(volume)])),
                              TestZip.File(name: "2.jpg", data: Data([2, UInt8(volume)]))])
                .write(to: mangas.appendingPathComponent("Akira/Akira 0\(volume).cbz"))
        }
        try TestZip.make([TestZip.File(name: "1.jpg", data: Data([1]))]).write(to: comics.appendingPathComponent("Blacksad/Blacksad 01.cbz"))
        try Data("notes".utf8).write(to: mangas.appendingPathComponent("Akira/notes.txt"))

        var config = ServerConfig(configDirectory: folder.appendingPathComponent("config"))
        config.onlineMetadata = false
        let store = try Store(path: folder.appendingPathComponent("config/library.sqlite").path)
        let mangaID = try store.addLibrary(name: "Mangas", path: mangas.path)
        let comicsID = try store.addLibrary(name: "BD", path: comics.path)
        let context = try ServerContext(config: config, store: store)
        await context.scanner.scanNow(mangaID)
        await context.scanner.scanNow(comicsID)
        var router = Router()
        APIRoutes.add(to: &router, context: context)
        OPDSRoutes.add(to: &router, context: context)
        let info = try Self.decode(APIRoutes.ServerInfo.self, await router.handle(Self.request("/api/v1/server")))
        #expect(info.setupRequired)

        let admin = try #require(store.user(id: try store.createUser(name: "Admin", passwordHash: Passwords.hash("password1", iterations: 1000),
                                                                     isAdmin: true, allLibraries: true, libraryIDs: [])))
        let lea = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: Passwords.hash("password2", iterations: 1000),
                                                                   isAdmin: false, allLibraries: false, libraryIDs: [comicsID])))
        let adminToken = try context.issueToken(for: admin, deviceName: "Test", kind: "app")
        let leaToken = try context.issueToken(for: lea, deviceName: "Test", kind: "app")

        #expect(await router.handle(Self.request("/api/v1/libraries")).status == .unauthorized)
        let libraries = try Self.decode([APIRoutes.LibraryInfo].self, await router.handle(Self.request("/api/v1/libraries", token: adminToken)))
        #expect(libraries.map(\.name) == ["BD", "Mangas"])
        let series = try Self.decode([APIRoutes.SeriesInfo].self,
                                     await router.handle(Self.request("/api/v1/libraries/\(mangaID)/series", token: adminToken)))
        #expect(series.map(\.title) == ["Akira"])
        let akira = try #require(series.first)
        #expect(akira.bookCount == 2)
        #expect(akira.kind == "volume")
        let detail = try Self.decode(APIRoutes.SeriesDetail.self, await router.handle(Self.request("/api/v1/series/\(akira.id)", token: adminToken)))
        #expect(detail.books.map(\.number) == [1, 2])
        #expect(detail.books.map(\.pageCount) == [2, 2])
        let first = try #require(detail.books.first)
        let page = await router.handle(Self.request("/api/v1/books/\(first.id)/pages/0", token: adminToken))
        #expect(Self.body(page) == Data([2, 1]))

        // Léa only has the BD.
        #expect(await router.handle(Self.request("/api/v1/series/\(akira.id)", token: leaToken)).status == .notFound)
        #expect(await router.handle(Self.request("/api/v1/books/\(first.id)/file", token: leaToken)).status == .notFound)
        let hers = try Self.decode([APIRoutes.LibraryInfo].self, await router.handle(Self.request("/api/v1/libraries", token: leaToken)))
        #expect(hers.map(\.name) == ["BD"])

        // OPDS readers sign in with a name and password.
        #expect(await router.handle(Self.request("/opds/v1.2/catalog")).status == .unauthorized)
        let catalog = await router.handle(Self.request("/opds/v1.2/catalog", basic: "Lea:password2"))
        let feed = String(decoding: Self.body(catalog), as: UTF8.self)
        #expect(catalog.status == .ok)
        #expect(feed.contains("<title>BD</title>") && !feed.contains("Mangas"))
        #expect(await router.handle(Self.request("/opds/v1.2/catalog", basic: "Lea:wrong")).status == .unauthorized)

        // Progress, per member.
        let saved = await router.handle(Self.request("/api/v1/books/\(first.id)/progress", method: .PUT, token: adminToken, body: #"{"page": 1}"#))
        #expect(saved.status == .ok)
        let progress = try Self.decode([APIRoutes.ProgressInfo].self, await router.handle(Self.request("/api/v1/progress", token: adminToken)))
        #expect(progress.map(\.page) == [1])

        // A file gone: the next scan forgets its book, and a scan of an unreachable folder keeps everything.
        try FileManager.default.removeItem(at: mangas.appendingPathComponent("Akira/Akira 02.cbz"))
        await context.scanner.scanNow(mangaID)
        #expect(store.books(seriesID: akira.id).count == 1)
        try FileManager.default.moveItem(at: mangas, to: folder.appendingPathComponent("library/Moved"))
        await context.scanner.scanNow(mangaID)
        #expect(store.books(seriesID: akira.id).count == 1)
        #expect(store.library(id: mangaID)?.lastError == "unreachable")
    }

    /// The pages in the browser: what a member reads shows on the home page, the reader turns manga right to left,
    /// and a book marked read sends the series' button on to the next one.
    @Test func readsInTheBrowser() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mangas = folder.appendingPathComponent("Mangas")
        try FileManager.default.createDirectory(at: mangas.appendingPathComponent("Akira"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("config"), withIntermediateDirectories: true)
        for volume in 1...2 {
            let pages = (1...3).map { (page: Int) -> TestZip.File in TestZip.File(name: "\(page).jpg", data: Data([UInt8(page)])) }
            try TestZip.make(pages).write(to: mangas.appendingPathComponent("Akira/Akira 0\(volume).cbz"))
        }
        var config = ServerConfig(configDirectory: folder.appendingPathComponent("config"))
        config.onlineMetadata = false
        let store = try Store(path: folder.appendingPathComponent("config/library.sqlite").path)
        let library = try store.addLibrary(name: "Mangas", path: mangas.path)
        let reader = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: "", isAdmin: false, allLibraries: true,
                                                                      libraryIDs: [])))
        let context = try ServerContext(config: config, store: store)
        await context.scanner.scanNow(library)
        var router = Router()
        APIRoutes.add(to: &router, context: context)
        CollectionRoutes.add(to: &router, context: context)
        let token = try context.issueToken(for: reader, deviceName: "Test", kind: "web")
        let series = try #require(store.series(libraryID: library).first)
        let books = store.books(seriesID: series.id)
        #expect(books.count == 2)

        let page = String(decoding: Self.body(await router.handle(Self.request("/read/\(books[0].id)", token: token))), as: UTF8.self)
        #expect(page.contains("data-count=\"3\"") && page.contains("data-rtl=\"1\"") && page.contains("data-start=\"0\""))

        // A page past the end stays on the last one, and the home page offers to carry on.
        let saved = await router.handle(Self.request("/api/v1/books/\(books[0].id)/progress", method: .PUT, token: token, body: #"{"page": 9}"#))
        #expect(try Self.decode(APIRoutes.ProgressInfo.self, saved).page == 2)
        _ = await router.handle(Self.request("/api/v1/books/\(books[0].id)/progress", method: .PUT, token: token, body: #"{"page": 1}"#))
        let home = String(decoding: Self.body(await router.handle(Self.request("/", token: token))), as: UTF8.self)
        #expect(home.contains("/read/\(books[0].id)"))
        let resumed = String(decoding: Self.body(await router.handle(Self.request("/read/\(books[0].id)", token: token))), as: UTF8.self)
        #expect(resumed.contains("data-start=\"1\""))

        var marked = Self.request("/books/\(books[0].id)/read", method: .POST, token: token, body: "read=1")
        marked.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        #expect(await router.handle(marked).status == .seeOther)
        #expect(store.progress(userID: reader.id, bookID: books[0].id)?.finished == true)
        let detail = String(decoding: Self.body(await router.handle(Self.request("/series/\(series.id)", token: token))), as: UTF8.self)
        #expect(detail.contains("href=\"/read/\(books[1].id)\""))
    }

    @Test func turnsMangaRightToLeft() throws {
        func book(rightToLeft: Bool?) -> BookRecord {
            var metadata = EmbeddedMetadata()
            metadata.isRightToLeft = rightToLeft
            return BookRecord(id: 1, seriesID: 1, libraryID: 1, path: "a.cbz", fileName: "a.cbz", format: .cbz, fileSize: 1, modifiedAt: nil,
                              number: 1, extraTitle: nil, plainName: "a", position: 0, pageCount: 3, coverPath: nil, pagePaths: ["1.jpg"],
                              isText: false, metadata: metadata, analysisError: nil, addedAt: Date())
        }
        func series(language: String?, folder: String) -> SeriesRecord {
            var match: SeriesMatch?
            if let language {
                match = SeriesMatch(source: .anilist)
                match?.originalLanguage = language
            }
            return SeriesRecord(id: 1, libraryID: 1, key: "k", folderTitle: "A", folderPath: folder, kind: .volume, posterPath: nil,
                                bannerPath: nil, nfo: nil, matchStatus: "matched", match: match, addedAt: Date(), bookCount: 1)
        }
        let comics = LibraryRecord(id: 1, name: "BD", path: "/BD", lastScanAt: nil, lastError: nil, seriesCount: 1, bookCount: 1)
        #expect(CollectionRoutes.isRightToLeft(book(rightToLeft: nil), series: series(language: "ja", folder: "A"), library: comics))
        #expect(!CollectionRoutes.isRightToLeft(book(rightToLeft: nil), series: series(language: "ko", folder: "Manga/A"), library: comics))
        #expect(!CollectionRoutes.isRightToLeft(book(rightToLeft: false), series: series(language: "ja", folder: "A"), library: comics))
        #expect(CollectionRoutes.isRightToLeft(book(rightToLeft: nil), series: series(language: nil, folder: "Mangas/A"), library: comics))
        #expect(!CollectionRoutes.isRightToLeft(book(rightToLeft: nil), series: series(language: nil, folder: "A"), library: comics))
    }

    static func request(_ path: String, method: HTTPMethod = .GET, token: String? = nil, basic: String? = nil, body: String = "") -> Request {
        var headers = HTTPHeaders()
        if let token { headers.add(name: "Authorization", value: "Bearer \(token)") }
        if let basic { headers.add(name: "Authorization", value: "Basic \(Data(basic.utf8).base64EncodedString())") }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        return Request(method: method, path: parts[0], query: parts.count > 1 ? Request.decodeQuery(parts[1]) : [:], headers: headers,
                       body: Data(body.utf8))
    }

    static func body(_ response: Response) -> Data {
        if case .data(let data) = response.body { return data }
        return Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ response: Response) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body(response))
    }
}
