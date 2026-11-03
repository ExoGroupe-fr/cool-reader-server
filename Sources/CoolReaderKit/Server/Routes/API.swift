import Crypto
import Foundation
import NIOHTTP1

/// The JSON API Cool Reader uses: libraries, series, books, files, pages, progress, and pairing.
nonisolated enum APIRoutes {
    struct ServerInfo: Codable {
        var name: String
        var id: String
        var version: String
        var apiVersion = 1
        var setupRequired: Bool
        /// SHA-256 of the server's certificate, lowercase hex. The app pins it.
        var fingerprint: String
    }

    struct Addresses: Codable {
        /// "host:port", best first: the home network's, then the public ones when remote access works.
        var addresses: [String]
    }

    struct LibraryContents: Codable {
        var library: LibraryInfo
        var series: [SeriesInfo]
        /// Without progress: that comes from /api/v1/progress.
        var books: [BookInfo]
    }

    struct Redeem: Decodable {
        var invitation: String
        var device: String
    }

    struct UserInfo: Codable {
        var id: Int
        var name: String
        var isAdmin: Bool
    }

    struct LibraryInfo: Codable {
        var id: Int
        var name: String
        var seriesCount: Int
        var bookCount: Int
    }

    struct SeriesInfo: Codable {
        var id: Int
        var libraryID: Int
        var title: String
        var folderTitle: String
        /// volume, chapter, issue or book.
        var kind: String
        var summary: String?
        var authors: [String]
        var genres: [String]
        var year: Int?
        var status: String?
        /// pending, matched, unmatched or ignored.
        var matchStatus: String
        /// anilist, mangadex, appleBooks or openLibrary.
        var source: String?
        var anilistID: Int?
        var bookCount: Int
        var coverURL: String
        var bannerURL: String?
        var addedAt: Date
    }

    struct BookInfo: Codable {
        var id: Int
        var seriesID: Int
        var fileName: String
        var format: String
        var size: Int64
        var number: Double?
        var title: String?
        var pageCount: Int?
        var isText: Bool
        var isRightToLeft: Bool?
        var coverURL: String
        var fileURL: String
        var progress: ProgressInfo?
    }

    struct ProgressInfo: Codable {
        var bookID: Int
        var page: Int
        var finished: Bool
        var position: String?
        var fraction: Double?
        var updatedAt: Date
    }

    struct SeriesDetail: Codable {
        var series: SeriesInfo
        var books: [BookInfo]
    }

    struct Login: Decodable {
        var name: String
        var password: String
        var device: String?
    }

    struct Token: Codable {
        var token: String
        var user: UserInfo
    }

    struct PairingStart: Decodable { var device: String }

    struct PairingInfo: Codable {
        var id: String
        var code: String
        var expiresIn: Int
    }

    struct PairingStatus: Codable {
        /// pending or approved; the token comes once, with approved.
        var status: String
        var token: String?
        var user: UserInfo?
    }

    struct ProgressUpdate: Decodable {
        var page: Int
        var finished: Bool?
        /// The app's own position in a text book, kept as it is.
        var position: String?
        var fraction: Double?
        /// When it was read; the newer of two updates wins. Now when missing.
        var updatedAt: Date?
    }

    static func add(to router: inout Router, context: ServerContext) {
        router.add(.GET, "/api/v1/server") { _ in
            .json(ServerInfo(name: context.serverName, id: context.serverID, version: ServerContext.version,
                             setupRequired: await context.setup.isNeeded, fingerprint: context.certificate.fingerprint))
        }

        router.add(.GET, "/api/v1/server/addresses") { request in
            _ = try await context.requireCaller(request)
            return .json(Addresses(addresses: await context.currentAddresses(requestHost: nil)))
        }

        router.add(.POST, "/api/v1/invitations/redeem") { request in
            let redeem = try decode(Redeem.self, request)
            guard let (token, user) = try await context.redeem(invitation: redeem.invitation, deviceName: redeem.device,
                                                               from: request.remoteAddress) else {
                throw HTTPError(status: .gone, message: "This invitation is unknown, used or expired. Ask for a new one.")
            }
            Log.info("« \(redeem.device.prefix(60)) » joined as \(user.name) with an invitation.")
            return .json(Token(token: token, user: info(user)))
        }

        router.add(.POST, "/api/v1/login") { request in
            let login = try decode(Login.self, request)
            let user = try await context.signIn(name: login.name, password: login.password, from: request.remoteAddress)
            let token = try context.issueToken(for: user, deviceName: login.device ?? "Cool Reader", kind: "app")
            return .json(Token(token: token, user: info(user)))
        }

        router.add(.POST, "/api/v1/logout") { request in
            let caller = try await context.requireCaller(request)
            if let device = caller.device { try context.store.removeDevice(id: device.id) }
            return .json(["status": "signed out"])
        }

        router.add(.POST, "/api/v1/pair") { request in
            let start = try decode(PairingStart.self, request)
            let pending = await context.pairings.start(deviceName: start.device)
            return .json(PairingInfo(id: pending.id, code: pending.code, expiresIn: 600))
        }

        router.add(.GET, "/api/v1/pair/:id") { request in
            guard let id = request.parameters["id"], let pending = await context.pairings.collect(id: id) else { throw HTTPError.notFound }
            guard let token = pending.token, let name = pending.userName, let (user, _) = context.store.credentials(name: name) else {
                return .json(PairingStatus(status: "pending"))
            }
            return .json(PairingStatus(status: "approved", token: token, user: info(user)))
        }

        router.add(.GET, "/api/v1/me") { request in
            let caller = try await context.requireCaller(request)
            return .json(info(caller.user))
        }

        router.add(.GET, "/api/v1/libraries") { request in
            let caller = try await context.requireCaller(request)
            return .json(context.store.visibleLibraries(for: caller.user).map {
                LibraryInfo(id: $0.id, name: $0.name, seriesCount: $0.seriesCount, bookCount: $0.bookCount)
            })
        }

        router.add(.GET, "/api/v1/libraries/:id/series") { request in
            let caller = try await context.requireCaller(request)
            let library = try context.visibleLibrary(request.parameter("id"), for: caller)
            return .json(context.store.series(libraryID: library.id).map(info))
        }

        router.add(.GET, "/api/v1/libraries/:id/contents") { request in
            let caller = try await context.requireCaller(request)
            let library = try context.visibleLibrary(request.parameter("id"), for: caller)
            let contents = LibraryContents(
                library: LibraryInfo(id: library.id, name: library.name, seriesCount: library.seriesCount, bookCount: library.bookCount),
                series: context.store.series(libraryID: library.id).map(info),
                books: context.store.books(libraryID: library.id).map { info($0, progress: nil) })
            return conditional(.json(contents), request: request)
        }

        router.add(.GET, "/api/v1/search") { request in
            let caller = try await context.requireCaller(request)
            let text = request.query["q"] ?? ""
            return .json(context.store.searchSeries(text, libraryIDs: context.visibleLibraryIDs(for: caller)).map(info))
        }

        router.add(.GET, "/api/v1/series/:id") { request in
            let caller = try await context.requireCaller(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            let progress = Dictionary(context.store.progress(userID: caller.user.id).map { ($0.bookID, $0) }, uniquingKeysWith: { $1 })
            let books = context.store.books(seriesID: series.id).map { info($0, progress: progress[$0.id]) }
            return .json(SeriesDetail(series: info(series), books: books))
        }

        router.add(.GET, "/api/v1/series/:id/cover") { request in
            let caller = try await context.requireCaller(request)
            let (series, root) = try context.visibleSeries(request.parameter("id"), for: caller)
            guard let image = await context.images.seriesCover(series, books: context.store.books(seriesID: series.id), root: root) else {
                throw HTTPError.notFound
            }
            return .image(image.data, contentType: image.contentType)
        }

        router.add(.GET, "/api/v1/series/:id/banner") { request in
            let caller = try await context.requireCaller(request)
            let (series, root) = try context.visibleSeries(request.parameter("id"), for: caller)
            guard let image = await context.images.banner(series, root: root) else { throw HTTPError.notFound }
            return .image(image.data, contentType: image.contentType)
        }

        router.add(.GET, "/api/v1/books/:id") { request in
            let caller = try await context.requireCaller(request)
            let (book, _, _) = try context.visibleBook(request.parameter("id"), for: caller)
            return .json(info(book, progress: context.store.progress(userID: caller.user.id, bookID: book.id)))
        }

        router.add(.GET, "/api/v1/books/:id/file") { request in
            let caller = try await context.requireCaller(request)
            let (book, _, root) = try context.visibleBook(request.parameter("id"), for: caller)
            return .file(root.appendingPathComponent(book.path), contentType: book.format.mediaType, fileName: book.fileName, request: request)
        }

        router.add(.GET, "/api/v1/books/:id/cover") { request in
            let caller = try await context.requireCaller(request)
            let (book, series, root) = try context.visibleBook(request.parameter("id"), for: caller)
            guard let image = await context.images.bookCover(book, series: series, root: root) else { throw HTTPError.notFound }
            return .image(image.data, contentType: image.contentType)
        }

        router.add(.GET, "/api/v1/books/:id/pages/:index") { request in
            let caller = try await context.requireCaller(request)
            let (book, _, root) = try context.visibleBook(request.parameter("id"), for: caller)
            guard let index = request.parameter("index") else { throw HTTPError.notFound }
            let width = request.query["width"].flatMap(Double.init).map { min(max($0, 200), 4000) }
            let page = try context.images.page(book, index: index, maxWidth: width, root: root)
            return .image(page.data, contentType: page.contentType)
        }

        router.add(.PUT, "/api/v1/books/:id/progress") { request in
            let caller = try await context.requireCaller(request)
            let (book, _, _) = try context.visibleBook(request.parameter("id"), for: caller)
            let update = try decode(ProgressUpdate.self, request)
            let fraction = update.fraction.map { min(max($0, 0), 1) }
            try context.store.setProgress(userID: caller.user.id, ProgressRecord(
                bookID: book.id, page: max(0, update.page), finished: update.finished ?? false,
                position: update.position.map { String($0.prefix(2000)) }, fraction: fraction,
                updatedAt: min(update.updatedAt ?? Date(), Date())))
            return .json(context.store.progress(userID: caller.user.id, bookID: book.id).map(info))
        }

        router.add(.GET, "/api/v1/progress") { request in
            let caller = try await context.requireCaller(request)
            let since = request.query["since"].flatMap { ISO8601DateFormatter().date(from: $0) }
            return .json(context.store.progress(userID: caller.user.id, since: since).map(info))
        }
    }

    /// A 304 instead of `response` when the client already has it: the app checks a library's contents often.
    static func conditional(_ response: Response, request: Request) -> Response {
        guard case .data(let data) = response.body else { return response }
        let tag = "\"" + SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
        var response = response
        response.headers.add(name: "ETag", value: tag)
        response.headers.add(name: "Cache-Control", value: "private, no-cache")
        if request.header("If-None-Match") == tag {
            response.status = .notModified
            response.body = .data(Data())
        }
        return response
    }

    static func decode<T: Decodable>(_ type: T.Type, _ request: Request) throws -> T {
        do {
            return try request.json(type)
        } catch {
            throw HTTPError.badRequest("The request's JSON doesn't fit.")
        }
    }

    static func info(_ user: UserRecord) -> UserInfo {
        UserInfo(id: user.id, name: user.name, isAdmin: user.isAdmin)
    }

    static func info(_ series: SeriesRecord) -> SeriesInfo {
        SeriesInfo(id: series.id, libraryID: series.libraryID, title: series.title, folderTitle: series.folderTitle,
                   kind: series.kind.rawValue, summary: series.summary, authors: series.authors, genres: series.genres,
                   year: series.year, status: series.status, matchStatus: series.matchStatus, source: series.match?.source.rawValue,
                   anilistID: series.match?.anilistID, bookCount: series.bookCount, coverURL: "/api/v1/series/\(series.id)/cover",
                   bannerURL: series.bannerPath != nil || series.match?.bannerURL != nil ? "/api/v1/series/\(series.id)/banner" : nil,
                   addedAt: series.addedAt)
    }

    static func info(_ book: BookRecord, progress: ProgressRecord?) -> BookInfo {
        BookInfo(id: book.id, seriesID: book.seriesID, fileName: book.fileName, format: book.format.rawValue, size: book.fileSize,
                 number: book.number, title: book.extraTitle ?? (book.number == nil ? book.plainName : nil), pageCount: book.pageCount,
                 isText: book.isText, isRightToLeft: book.metadata?.isRightToLeft, coverURL: "/api/v1/books/\(book.id)/cover",
                 fileURL: "/api/v1/books/\(book.id)/file", progress: progress.map(info))
    }

    static func info(_ progress: ProgressRecord) -> ProgressInfo {
        ProgressInfo(bookID: progress.bookID, page: progress.page, finished: progress.finished, position: progress.position,
                     fraction: progress.fraction, updatedAt: progress.updatedAt)
    }
}
