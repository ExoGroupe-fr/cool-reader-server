import Foundation
import Testing
@testable import CoolReaderKit

/// What a member reads next, whole series marked read, and search by author and genre, on a library scanned for real.
struct ReadingTests {
    /// A library "Mangas" with Akira in three volumes, scanned offline, and a member who reads it.
    private static func library() async throws -> (folder: URL, store: Store, user: UserRecord, series: SeriesRecord, books: [BookRecord]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let akira = folder.appendingPathComponent("Mangas/Akira")
        try FileManager.default.createDirectory(at: akira, withIntermediateDirectories: true)
        for volume in 1...3 {
            let pages = (1...3).map { (page: Int) -> TestZip.File in TestZip.File(name: "\(page).jpg", data: Data([UInt8(page)])) }
            try TestZip.make(pages).write(to: akira.appendingPathComponent("Akira 0\(volume).cbz"))
        }
        var config = ServerConfig(configDirectory: folder.appendingPathComponent("config"))
        config.onlineMetadata = false
        try FileManager.default.createDirectory(at: config.configDirectory, withIntermediateDirectories: true)
        let store = try Store(path: config.configDirectory.appendingPathComponent("library.sqlite").path)
        let library = try store.addLibrary(name: "Mangas", path: folder.appendingPathComponent("Mangas").path)
        let user = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: "", isAdmin: false, allLibraries: true,
                                                                    libraryIDs: [])))
        let context = try ServerContext(config: config, store: store)
        await context.scanner.scanNow(library)
        let series = try #require(store.series(libraryID: library).first)
        return (folder, store, user, series, store.books(seriesID: series.id))
    }

    private static func read(_ book: BookRecord, finished: Bool, page: Int, store: Store, user: UserRecord) throws {
        try store.setProgress(userID: user.id, ProgressRecord(bookID: book.id, page: page, finished: finished, position: nil, fraction: nil,
                                                              updatedAt: Date()))
    }

    @Test func upNextIsTheNextVolumeNotBegun() async throws {
        let (folder, store, user, series, books) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(books.count == 3)
        #expect(store.upNext(userID: user.id, libraryIDs: [series.libraryID], limit: 10).isEmpty)
        try Self.read(books[0], finished: true, page: 2, store: store, user: user)
        #expect(store.upNext(userID: user.id, libraryIDs: [series.libraryID], limit: 10).map(\.id) == [books[1].id])
        // Begun, it is in "Reprendre la lecture" instead.
        try Self.read(books[1], finished: false, page: 1, store: store, user: user)
        #expect(store.upNext(userID: user.id, libraryIDs: [series.libraryID], limit: 10).isEmpty)
        try Self.read(books[1], finished: true, page: 2, store: store, user: user)
        #expect(store.upNext(userID: user.id, libraryIDs: [series.libraryID], limit: 10).map(\.id) == [books[2].id])
        #expect(store.startedSeries(userID: user.id) == [series.id])
    }

    @Test func aWholeSeriesIsMarkedReadOrUnread() async throws {
        let (folder, store, user, series, books) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.setSeriesRead(userID: user.id, seriesID: series.id, read: true)
        let read = store.progress(userID: user.id, seriesID: series.id)
        #expect(books.allSatisfy { read[$0.id]?.finished == true && read[$0.id]?.page == 2 })
        #expect(store.upNext(userID: user.id, libraryIDs: [series.libraryID], limit: 10).isEmpty)
        try store.setSeriesRead(userID: user.id, seriesID: series.id, read: false)
        let unread = store.progress(userID: user.id, seriesID: series.id)
        #expect(books.allSatisfy { unread[$0.id]?.finished == false && unread[$0.id]?.page == 0 })
    }

    @Test func searchFindsAuthorsAndGenres() async throws {
        let (folder, store, _, series, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: folder) }
        var match = SeriesMatch(source: .anilist)
        match.authors = ["Katsuhiro Ōtomo"]
        match.genres = ["Sci-Fi"]
        try store.setMatch(seriesID: series.id, status: "matched", match: match)
        #expect(store.searchSeries("otomo", libraryIDs: [series.libraryID]).map(\.id) == [series.id])
        #expect(store.searchSeries("sci-fi", libraryIDs: [series.libraryID]).map(\.id) == [series.id])
        // A genre in the member's language.
        #expect(store.searchSeries("science", libraryIDs: [series.libraryID]).isEmpty)
        #expect(store.searchSeries("science", libraryIDs: [series.libraryID]) { [$0, Strings("fr").genre($0)] }.map(\.id) == [series.id])
    }
}
