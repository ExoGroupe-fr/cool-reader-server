import Foundation

nonisolated struct LibraryRecord: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var path: String
    var lastScanAt: Date?
    var lastError: String?
    var seriesCount: Int
    var bookCount: Int
}

nonisolated struct SeriesRecord: Sendable {
    var id: Int
    var libraryID: Int
    var key: String
    var folderTitle: String
    var folderPath: String?
    var kind: UnitKind
    var posterPath: String?
    var bannerPath: String?
    var nfo: NFOInfo?
    /// pending, matched, unmatched or ignored.
    var matchStatus: String
    var match: SeriesMatch?
    var addedAt: Date
    var bookCount: Int
    /// The admin's own title and synopsis, over the catalogues' and the .nfo's.
    var customTitle: String? = nil
    var customSummary: String? = nil

    var title: String { customTitle ?? match?.title ?? nfo?.title ?? folderTitle }
    /// Entities decoded here too, for the synopses kept before the store's were.
    var summary: String? { (customSummary ?? match?.summary ?? nfo?.summary).map(EPUBText.decodingEntities) }
    var authors: [String] { match?.authors.isEmpty == false ? match!.authors : (nfo?.authors ?? []) }
    var genres: [String] { match?.genres.isEmpty == false ? match!.genres : (nfo?.genres ?? []) }
    var year: Int? { match?.year ?? nfo?.year }
    var status: String? { match?.status ?? nfo?.status }
}

nonisolated struct BookRecord: Sendable {
    var id: Int
    var seriesID: Int
    var libraryID: Int
    var path: String
    var fileName: String
    var format: BookFormat
    var fileSize: Int64
    var modifiedAt: Date?
    var number: Double?
    var extraTitle: String?
    var plainName: String
    var position: Int
    var pageCount: Int?
    var coverPath: String?
    var pagePaths: [String]
    var isText: Bool
    var metadata: EmbeddedMetadata?
    var analysisError: String?
    var addedAt: Date
}

nonisolated struct UserRecord: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var isAdmin: Bool
    /// Sees every library, those added later too.
    var allLibraries: Bool
    var libraryIDs: [Int]

    func canSee(library: Int) -> Bool { isAdmin || allLibraries || libraryIDs.contains(library) }
}

nonisolated struct DeviceRecord: Codable, Sendable {
    var id: Int
    var userID: Int
    var name: String
    /// app, opds or web.
    var kind: String
    var createdAt: Date
    var lastSeenAt: Date?
}

nonisolated struct ProgressRecord: Codable, Sendable, Equatable {
    var bookID: Int
    var page: Int
    var finished: Bool
    /// Where a text book is open, in the app's own words; the server only keeps it.
    var position: String?
    /// How much is read, 0 to 1.
    var fraction: Double?
    var updatedAt: Date
}

/// A link that signs one device in as a member, once, before it expires. Only the secret's SHA-256 is stored.
nonisolated struct InvitationRecord: Sendable, Equatable {
    var id: Int
    var userID: Int
    var createdAt: Date
    var expiresAt: Date
    var usedAt: Date?
}

/// What a scan found for one file: its analysis, or why it couldn't be read.
nonisolated enum BookScan: Sendable {
    case analysed(BookAnalysis)
    case failed(String)
    /// Unchanged since the last scan: keep what is stored.
    case unchanged
}

/// The server's tables and the queries the routes need.
nonisolated final class Store: Sendable {
    let database: Database

    init(path: String) throws {
        database = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        let version = try database.first("PRAGMA user_version")?.int("user_version") ?? 0
        if version < 1 { try createTables() }
        if version < 2 {
            try database.transaction {
                try database.execute("""
                    CREATE TABLE invitations (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                        secret_hash TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, expires_at REAL NOT NULL, used_at REAL)
                    """)
                try database.execute("ALTER TABLE progress ADD COLUMN position TEXT")
                try database.execute("ALTER TABLE progress ADD COLUMN fraction REAL")
                try database.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try database.transaction {
                try database.execute("ALTER TABLE series ADD COLUMN custom_title TEXT")
                try database.execute("ALTER TABLE series ADD COLUMN custom_summary TEXT")
                try database.execute("PRAGMA user_version = 3")
            }
        }
    }

    private func createTables() throws {
        try database.transaction {
            try database.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try database.execute("""
                CREATE TABLE libraries (id INTEGER PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL, last_scan_at REAL, last_error TEXT)
                """)
            try database.execute("""
                CREATE TABLE series (id INTEGER PRIMARY KEY, library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                    key TEXT NOT NULL, folder_title TEXT NOT NULL, folder_path TEXT, kind TEXT NOT NULL,
                    poster_path TEXT, banner_path TEXT, nfo_json TEXT,
                    match_status TEXT NOT NULL DEFAULT 'pending', match_json TEXT, matched_at REAL,
                    added_at REAL NOT NULL, updated_at REAL NOT NULL, UNIQUE (library_id, key))
                """)
            try database.execute("""
                CREATE TABLE books (id INTEGER PRIMARY KEY, series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
                    library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                    path TEXT NOT NULL, file_name TEXT NOT NULL, format TEXT NOT NULL, file_size INTEGER NOT NULL, modified_at REAL,
                    number REAL, extra_title TEXT, plain_name TEXT NOT NULL, position INTEGER NOT NULL,
                    page_count INTEGER, cover_path TEXT, pages_json TEXT, is_text INTEGER NOT NULL DEFAULT 0, metadata_json TEXT,
                    analysis_error TEXT, analysed INTEGER NOT NULL DEFAULT 0, added_at REAL NOT NULL, UNIQUE (library_id, path))
                """)
            try database.execute("CREATE INDEX books_series ON books(series_id, position)")
            try database.execute("""
                CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, password_hash TEXT NOT NULL,
                    is_admin INTEGER NOT NULL DEFAULT 0, all_libraries INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE user_libraries (user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE, PRIMARY KEY (user_id, library_id))
                """)
            try database.execute("""
                CREATE TABLE devices (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    name TEXT NOT NULL, kind TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, last_seen_at REAL)
                """)
            try database.execute("""
                CREATE TABLE progress (user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE, page INTEGER NOT NULL,
                    finished INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL, PRIMARY KEY (user_id, book_id))
                """)
            try database.execute("PRAGMA user_version = 1")
        }
    }

    // MARK: - Settings

    func setting(_ key: String) -> String? {
        try? database.first("SELECT value FROM settings WHERE key = ?", [key])?.string("value")
    }

    func setSetting(_ key: String, _ value: String) throws {
        try database.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                             [key, value])
    }

    // MARK: - Libraries

    func libraries() -> [LibraryRecord] {
        let rows = (try? database.query("""
            SELECT l.*, (SELECT COUNT(*) FROM series s WHERE s.library_id = l.id) AS series_count,
                (SELECT COUNT(*) FROM books b WHERE b.library_id = l.id) AS book_count
            FROM libraries l ORDER BY l.name COLLATE NOCASE
            """)) ?? []
        return rows.map(library(from:))
    }

    func library(id: Int) -> LibraryRecord? {
        libraries().first { $0.id == id }
    }

    private func library(from row: Row) -> LibraryRecord {
        LibraryRecord(id: row.int("id") ?? 0, name: row.string("name") ?? "", path: row.string("path") ?? "",
                      lastScanAt: row.date("last_scan_at"), lastError: row.string("last_error"),
                      seriesCount: row.int("series_count") ?? 0, bookCount: row.int("book_count") ?? 0)
    }

    func addLibrary(name: String, path: String) throws -> Int {
        try database.insert("INSERT INTO libraries (name, path, created_at) VALUES (?, ?, ?)", [name, path, Date()])
    }

    func removeLibrary(id: Int) throws {
        try database.execute("DELETE FROM libraries WHERE id = ?", [id])
    }

    func setScanned(libraryID: Int, error: String?) throws {
        try database.execute("UPDATE libraries SET last_scan_at = ?, last_error = ? WHERE id = ?", [Date(), error, libraryID])
    }

    // MARK: - Scans

    /// The books known in a library, by path: what a scan compares the files with. A PDF without a page count
    /// was read where nothing could count its pages (Linux without poppler): it is read again.
    func knownBooks(libraryID: Int) -> [String: (size: Int64, modified: Double?, analysed: Bool)] {
        let rows = (try? database.query("SELECT path, file_size, modified_at, analysed, format, page_count FROM books WHERE library_id = ?",
                                        [libraryID])) ?? []
        var known: [String: (size: Int64, modified: Double?, analysed: Bool)] = [:]
        for row in rows {
            let uncounted = row.string("format") == BookFormat.pdf.rawValue && row.int("page_count") == nil
            known[row.string("path") ?? ""] = (Int64(row.int("file_size") ?? 0), row.double("modified_at"), row.bool("analysed") && !uncounted)
        }
        return known
    }

    /// Writes a scan: series and books found, the books gone removed (except in folders that couldn't be listed),
    /// and the series left empty. Returns the number of books added.
    @discardableResult
    func applyScan(libraryID: Int, drafts: [SeriesDraft], nfo: [String: NFOInfo], books: [String: BookScan],
                   result: ScanResult) throws -> Int {
        let encoder = JSONEncoder()
        let now = Date()
        var added = 0
        try database.transaction {
            var seen: Set<String> = []
            for draft in drafts {
                let nfoJSON = draft.nfoPath.flatMap { nfo[$0] }.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                try database.execute("""
                    INSERT INTO series (library_id, key, folder_title, folder_path, kind, poster_path, banner_path, nfo_json, added_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(library_id, key) DO UPDATE SET folder_title = excluded.folder_title, folder_path = excluded.folder_path,
                        kind = excluded.kind, poster_path = excluded.poster_path, banner_path = excluded.banner_path,
                        nfo_json = excluded.nfo_json, updated_at = excluded.updated_at
                    """, [libraryID, draft.key, draft.title, draft.folderPath, draft.kind.rawValue, draft.posterPath, draft.bannerPath,
                          nfoJSON, now, now])
                guard let seriesID = try database.first("SELECT id FROM series WHERE library_id = ? AND key = ?",
                                                        [libraryID, draft.key])?.int("id") else { continue }
                var filesChanged = false
                for (position, book) in draft.books.enumerated() {
                    let scanned = book.scanned
                    seen.insert(scanned.relativePath)
                    let exists = try database.first("SELECT id FROM books WHERE library_id = ? AND path = ?",
                                                    [libraryID, scanned.relativePath]) != nil
                    if !exists {
                        added += 1
                        filesChanged = true
                    }
                    try database.execute("""
                        INSERT INTO books (series_id, library_id, path, file_name, format, file_size, modified_at, number, extra_title,
                            plain_name, position, added_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(library_id, path) DO UPDATE SET series_id = excluded.series_id, file_name = excluded.file_name,
                            format = excluded.format, file_size = excluded.file_size, modified_at = excluded.modified_at,
                            number = excluded.number, extra_title = excluded.extra_title, plain_name = excluded.plain_name,
                            position = excluded.position
                        """, [seriesID, libraryID, scanned.relativePath, scanned.fileName, scanned.format.rawValue, scanned.fileSize,
                              scanned.modifiedAt, book.number, book.extraTitle, book.plainName, position, now])
                    switch books[scanned.relativePath] ?? .unchanged {
                    case .unchanged:
                        break
                    case .failed(let message):
                        filesChanged = true
                        try database.execute("""
                            UPDATE books SET analysed = 1, analysis_error = ?, page_count = NULL, cover_path = NULL, pages_json = NULL,
                                metadata_json = NULL WHERE library_id = ? AND path = ?
                            """, [message, libraryID, scanned.relativePath])
                    case .analysed(let analysis):
                        filesChanged = true
                        let pages = (try? encoder.encode(analysis.pagePaths)).map { String(decoding: $0, as: UTF8.self) }
                        let metadata = analysis.metadata.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                        try database.execute("""
                            UPDATE books SET analysed = 1, analysis_error = NULL, page_count = ?, cover_path = ?, pages_json = ?,
                                is_text = ?, metadata_json = ? WHERE library_id = ? AND path = ?
                            """, [analysis.pageCount, analysis.coverPath, pages, analysis.isText, metadata, libraryID, scanned.relativePath])
                    }
                }
                // A series the catalogues didn't know is looked up again when its files change: a book renamed
                // after the first scan, or one more volume, may be what was missing.
                if filesChanged {
                    try database.execute("UPDATE series SET match_status = 'pending' WHERE id = ? AND match_status = 'unmatched'",
                                         [seriesID])
                }
            }
            for path in knownBooks(libraryID: libraryID).keys where !seen.contains(path) && !result.isInUnreadableFolder(path) {
                try database.execute("DELETE FROM books WHERE library_id = ? AND path = ?", [libraryID, path])
            }
            try database.execute("DELETE FROM series WHERE library_id = ? AND NOT EXISTS (SELECT 1 FROM books b WHERE b.series_id = series.id)",
                                 [libraryID])
        }
        return added
    }

    // MARK: - Series and books

    private let seriesColumns = """
        s.*, (SELECT COUNT(*) FROM books b WHERE b.series_id = s.id) AS book_count
        """

    func series(libraryID: Int) -> [SeriesRecord] {
        let rows = (try? database.query("SELECT \(seriesColumns) FROM series s WHERE s.library_id = ?", [libraryID])) ?? []
        return rows.map(series(from:)).sorted { NaturalOrder.less($0.title, $1.title) }
    }

    func series(id: Int) -> SeriesRecord? {
        (try? database.first("SELECT \(seriesColumns) FROM series s WHERE s.id = ?", [id])).flatMap { $0.map(series(from:)) }
    }

    /// The series added last, in the libraries a member sees.
    func recentSeries(libraryIDs: [Int], limit: Int) -> [SeriesRecord] {
        guard !libraryIDs.isEmpty else { return [] }
        let marks = libraryIDs.map { _ in "?" }.joined(separator: ",")
        let rows = (try? database.query("""
            SELECT \(seriesColumns) FROM series s WHERE s.library_id IN (\(marks)) ORDER BY s.added_at DESC LIMIT ?
            """, libraryIDs.map { $0 as (any SQLBindable)? } + [limit])) ?? []
        return rows.map(series(from:))
    }

    /// Series whose title, folder, authors or genres hold the text; `genreNames` adds a genre's names in the member's
    /// language ("Aventure" for "Adventure").
    func searchSeries(_ text: String, libraryIDs: [Int], genreNames: (String) -> [String] = { [$0] }) -> [SeriesRecord] {
        let wanted = FileNameParser.normalized(text)
        guard !wanted.isEmpty else { return [] }
        return libraryIDs.flatMap { series(libraryID: $0) }.filter { series in
            let fields = [series.title, series.folderTitle] + series.authors + series.genres.flatMap(genreNames)
            return fields.contains { FileNameParser.normalized($0).contains(wanted) }
        }
    }

    func pendingSeries(limit: Int) -> [Int] {
        ((try? database.query("SELECT id FROM series WHERE match_status = 'pending' ORDER BY added_at LIMIT ?", [limit])) ?? [])
            .compactMap { $0.int("id") }
    }

    /// pending, matched, unmatched, manual (the admin's choice, never redone by the matcher) or ignored (no match, by
    /// the admin's choice). `onlyIfPending` leaves a series the admin settled in the meantime.
    func setMatch(seriesID: Int, status: String, match: SeriesMatch?, onlyIfPending: Bool = false) throws {
        let json = match.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try database.execute("UPDATE series SET match_status = ?, match_json = ?, matched_at = ? WHERE id = ?"
                             + (onlyIfPending ? " AND match_status = 'pending'" : ""), [status, json, Date(), seriesID])
    }

    /// Asks the matcher again for a series, its present match still shown meanwhile.
    func rematch(seriesID: Int) throws {
        try database.execute("UPDATE series SET match_status = 'pending' WHERE id = ?", [seriesID])
    }

    /// Forgets a book whose file is gone, and its series when it was the last one.
    func removeBook(id: Int) throws {
        guard let book = book(id: id) else { return }
        try database.transaction {
            try database.execute("DELETE FROM books WHERE id = ?", [id])
            try database.execute("DELETE FROM series WHERE id = ? AND NOT EXISTS (SELECT 1 FROM books b WHERE b.series_id = series.id)",
                                 [book.seriesID])
        }
    }

    /// The admin's title and synopsis for a series; nil gives the catalogues' back.
    func setCustom(seriesID: Int, title: String?, summary: String?) throws {
        try database.execute("UPDATE series SET custom_title = ?, custom_summary = ? WHERE id = ?", [title, summary, seriesID])
    }

    func resetMatches(status: String) throws {
        try database.execute("UPDATE series SET match_status = 'pending' WHERE match_status = ?", [status])
    }

    private func series(from row: Row) -> SeriesRecord {
        SeriesRecord(id: row.int("id") ?? 0, libraryID: row.int("library_id") ?? 0, key: row.string("key") ?? "",
                     folderTitle: row.string("folder_title") ?? "", folderPath: row.string("folder_path"),
                     kind: UnitKind(rawValue: row.string("kind") ?? "") ?? .volume, posterPath: row.string("poster_path"),
                     bannerPath: row.string("banner_path"), nfo: row.json("nfo_json", as: NFOInfo.self),
                     matchStatus: row.string("match_status") ?? "pending", match: row.json("match_json", as: SeriesMatch.self),
                     addedAt: row.date("added_at") ?? Date(), bookCount: row.int("book_count") ?? 0,
                     customTitle: row.string("custom_title"), customSummary: row.string("custom_summary"))
    }

    func books(seriesID: Int) -> [BookRecord] {
        ((try? database.query("SELECT * FROM books WHERE series_id = ? ORDER BY position", [seriesID])) ?? []).map(book(from:))
    }

    func books(libraryID: Int) -> [BookRecord] {
        ((try? database.query("SELECT * FROM books WHERE library_id = ? ORDER BY series_id, position", [libraryID])) ?? []).map(book(from:))
    }

    func book(id: Int) -> BookRecord? {
        (try? database.first("SELECT * FROM books WHERE id = ?", [id])).flatMap { $0.map(book(from:)) }
    }

    private func book(from row: Row) -> BookRecord {
        BookRecord(id: row.int("id") ?? 0, seriesID: row.int("series_id") ?? 0, libraryID: row.int("library_id") ?? 0,
                   path: row.string("path") ?? "", fileName: row.string("file_name") ?? "",
                   format: BookFormat(rawValue: row.string("format") ?? "") ?? .cbz, fileSize: Int64(row.int("file_size") ?? 0),
                   modifiedAt: row.date("modified_at"), number: row.double("number"), extraTitle: row.string("extra_title"),
                   plainName: row.string("plain_name") ?? "", position: row.int("position") ?? 0, pageCount: row.int("page_count"),
                   coverPath: row.string("cover_path"), pagePaths: row.json("pages_json", as: [String].self) ?? [],
                   isText: row.bool("is_text"), metadata: row.json("metadata_json", as: EmbeddedMetadata.self),
                   analysisError: row.string("analysis_error"), addedAt: row.date("added_at") ?? Date())
    }

    // MARK: - Users

    func userCount() -> Int {
        (try? database.first("SELECT COUNT(*) AS n FROM users")?.int("n")) ?? 0
    }

    func createUser(name: String, passwordHash: String, isAdmin: Bool, allLibraries: Bool, libraryIDs: [Int]) throws -> Int {
        try database.transaction {
            let id = try database.insert("""
                INSERT INTO users (name, password_hash, is_admin, all_libraries, created_at) VALUES (?, ?, ?, ?, ?)
                """, [name, passwordHash, isAdmin, allLibraries, Date()])
            for library in libraryIDs {
                try database.execute("INSERT INTO user_libraries (user_id, library_id) VALUES (?, ?)", [id, library])
            }
            return id
        }
    }

    func users() -> [UserRecord] {
        ((try? database.query("SELECT * FROM users ORDER BY is_admin DESC, name COLLATE NOCASE")) ?? []).map(user(from:))
    }

    func user(id: Int) -> UserRecord? {
        (try? database.first("SELECT * FROM users WHERE id = ?", [id])).flatMap { $0.map(user(from:)) }
    }

    /// The account and its password hash, for signing in.
    func credentials(name: String) -> (UserRecord, String)? {
        guard let row = try? database.first("SELECT * FROM users WHERE name = ?", [name]),
              let hash = row.string("password_hash") else { return nil }
        return (user(from: row), hash)
    }

    func setLibraries(userID: Int, all: Bool, libraryIDs: [Int]) throws {
        try database.transaction {
            try database.execute("UPDATE users SET all_libraries = ? WHERE id = ?", [all, userID])
            try database.execute("DELETE FROM user_libraries WHERE user_id = ?", [userID])
            for library in libraryIDs {
                try database.execute("INSERT INTO user_libraries (user_id, library_id) VALUES (?, ?)", [userID, library])
            }
        }
    }

    func setPassword(userID: Int, hash: String) throws {
        try database.execute("UPDATE users SET password_hash = ? WHERE id = ?", [hash, userID])
    }

    func removeUser(id: Int) throws {
        try database.execute("DELETE FROM users WHERE id = ? AND is_admin = 0", [id])
    }

    private func user(from row: Row) -> UserRecord {
        let id = row.int("id") ?? 0
        let libraries = ((try? database.query("SELECT library_id FROM user_libraries WHERE user_id = ?", [id])) ?? [])
            .compactMap { $0.int("library_id") }
        return UserRecord(id: id, name: row.string("name") ?? "", isAdmin: row.bool("is_admin"),
                          allLibraries: row.bool("all_libraries"), libraryIDs: libraries)
    }

    /// The libraries a member sees.
    func visibleLibraries(for user: UserRecord) -> [LibraryRecord] {
        libraries().filter { user.canSee(library: $0.id) }
    }

    // MARK: - Devices

    func addDevice(userID: Int, name: String, kind: String, tokenHash: String) throws -> Int {
        try database.insert("INSERT INTO devices (user_id, name, kind, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
                            [userID, name, kind, tokenHash, Date(), Date()])
    }

    func device(tokenHash: String) -> (DeviceRecord, UserRecord)? {
        guard let row = try? database.first("SELECT * FROM devices WHERE token_hash = ?", [tokenHash]),
              let user = user(id: row.int("user_id") ?? 0) else { return nil }
        return (device(from: row), user)
    }

    func devices() -> [DeviceRecord] {
        ((try? database.query("SELECT * FROM devices ORDER BY last_seen_at DESC")) ?? []).map(device(from:))
    }

    func removeDevice(id: Int) throws {
        try database.execute("DELETE FROM devices WHERE id = ?", [id])
    }

    func touchDevice(id: Int) {
        _ = try? database.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", [Date(), id])
    }

    private func device(from row: Row) -> DeviceRecord {
        DeviceRecord(id: row.int("id") ?? 0, userID: row.int("user_id") ?? 0, name: row.string("name") ?? "",
                     kind: row.string("kind") ?? "app", createdAt: row.date("created_at") ?? Date(), lastSeenAt: row.date("last_seen_at"))
    }

    // MARK: - Progress

    /// Keeps the newer of what is stored and `progress`: a device that read offline sends its progress later, with
    /// the time it was read.
    func setProgress(userID: Int, _ progress: ProgressRecord) throws {
        try database.execute("""
            INSERT INTO progress (user_id, book_id, page, finished, position, fraction, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, book_id) DO UPDATE SET page = excluded.page, finished = excluded.finished,
                position = excluded.position, fraction = excluded.fraction, updated_at = excluded.updated_at
            WHERE excluded.updated_at >= progress.updated_at
            """, [userID, progress.bookID, progress.page, progress.finished, progress.position, progress.fraction, progress.updatedAt])
    }

    func progress(userID: Int, since: Date? = nil) -> [ProgressRecord] {
        let rows = (try? database.query("SELECT * FROM progress WHERE user_id = ? AND updated_at > ? ORDER BY updated_at",
                                        [userID, since ?? Date(timeIntervalSince1970: 0)])) ?? []
        return rows.map(progress(from:))
    }

    func progress(userID: Int, bookID: Int) -> ProgressRecord? {
        (try? database.first("SELECT * FROM progress WHERE user_id = ? AND book_id = ?", [userID, bookID])).flatMap { $0.map(progress(from:)) }
    }

    private func progress(from row: Row) -> ProgressRecord {
        ProgressRecord(bookID: row.int("book_id") ?? 0, page: row.int("page") ?? 0, finished: row.bool("finished"),
                       position: row.string("position"), fraction: row.double("fraction"), updatedAt: row.date("updated_at") ?? Date())
    }

    // MARK: - Reading

    /// What a member is reading: books started and not finished, the last read first.
    func readingNow(userID: Int, libraryIDs: [Int], limit: Int) -> [(book: BookRecord, progress: ProgressRecord)] {
        guard !libraryIDs.isEmpty else { return [] }
        let marks = libraryIDs.map { _ in "?" }.joined(separator: ",")
        let arguments: [(any SQLBindable)?] = [userID] + libraryIDs.map { $0 as (any SQLBindable)? } + [limit]
        let rows = (try? database.query("""
            SELECT b.* FROM progress p JOIN books b ON b.id = p.book_id
            WHERE p.user_id = ? AND p.finished = 0 AND (p.page > 0 OR p.fraction > 0) AND b.library_id IN (\(marks))
            ORDER BY p.updated_at DESC LIMIT ?
            """, arguments)) ?? []
        return rows.map(book(from:)).compactMap { book in progress(userID: userID, bookID: book.id).map { (book, $0) } }
    }

    /// "À suivre", like Plex's On Deck: in each series a member has finished a book of, the next one they haven't
    /// begun, the series read last first. A book already begun is in "Reprendre la lecture" instead.
    func upNext(userID: Int, libraryIDs: [Int], limit: Int) -> [BookRecord] {
        guard !libraryIDs.isEmpty else { return [] }
        let marks = libraryIDs.map { _ in "?" }.joined(separator: ",")
        let arguments: [(any SQLBindable)?] = [userID] + libraryIDs.map { $0 as (any SQLBindable)? }
        let rows = (try? database.query("""
            SELECT b.series_id AS series_id, MAX(p.updated_at) AS last FROM progress p JOIN books b ON b.id = p.book_id
            WHERE p.user_id = ? AND p.finished = 1 AND b.library_id IN (\(marks)) GROUP BY b.series_id ORDER BY last DESC
            """, arguments)) ?? []
        var next: [BookRecord] = []
        for seriesID in rows.compactMap({ $0.int("series_id") }) where next.count < limit {
            let read = progress(userID: userID, seriesID: seriesID)
            let books = books(seriesID: seriesID)
            guard let lastFinished = books.lastIndex(where: { read[$0.id]?.finished == true }),
                  let book = books[(lastFinished + 1)...].first(where: { read[$0.id]?.finished != true }) else { continue }
            if let started = read[book.id], started.page > 0 || (started.fraction ?? 0) > 0 { continue }
            next.append(book)
        }
        return next
    }

    /// Marks every book of a series read (at its last page) or unread, as now: a member's devices take it up.
    func setSeriesRead(userID: Int, seriesID: Int, read: Bool) throws {
        let now = Date()
        try database.transaction {
            for book in books(seriesID: seriesID) {
                try setProgress(userID: userID, ProgressRecord(bookID: book.id, page: read ? max(0, (book.pageCount ?? 1) - 1) : 0,
                                                               finished: read, position: nil, fraction: read ? 1 : 0, updatedAt: now))
            }
        }
    }

    /// A member's progress in the books of a series, by book.
    func progress(userID: Int, seriesID: Int) -> [Int: ProgressRecord] {
        let rows = (try? database.query("""
            SELECT p.* FROM progress p JOIN books b ON b.id = p.book_id WHERE p.user_id = ? AND b.series_id = ?
            """, [userID, seriesID])) ?? []
        return Dictionary(rows.map(progress(from:)).map { ($0.bookID, $0) }, uniquingKeysWith: { $1 })
    }

    /// The series a member has begun: a book finished or opened past its first page.
    func startedSeries(userID: Int) -> Set<Int> {
        let rows = (try? database.query("""
            SELECT DISTINCT b.series_id AS series_id FROM progress p JOIN books b ON b.id = p.book_id
            WHERE p.user_id = ? AND (p.finished = 1 OR p.page > 0 OR p.fraction > 0)
            """, [userID])) ?? []
        return Set(rows.compactMap { $0.int("series_id") })
    }

    /// How many books of each series a member finished, by series.
    func finishedCounts(userID: Int) -> [Int: Int] {
        let rows = (try? database.query("""
            SELECT b.series_id AS series_id, COUNT(*) AS n FROM progress p JOIN books b ON b.id = p.book_id
            WHERE p.user_id = ? AND p.finished = 1 GROUP BY b.series_id
            """, [userID])) ?? []
        var counts: [Int: Int] = [:]
        for row in rows {
            if let id = row.int("series_id") { counts[id] = row.int("n") ?? 0 }
        }
        return counts
    }

    // MARK: - Invitations

    func addInvitation(userID: Int, secretHash: String, expiresAt: Date) throws -> Int {
        try database.insert("INSERT INTO invitations (user_id, secret_hash, created_at, expires_at) VALUES (?, ?, ?, ?)",
                            [userID, secretHash, Date(), expiresAt])
    }

    func invitation(secretHash: String) -> InvitationRecord? {
        (try? database.first("SELECT * FROM invitations WHERE secret_hash = ?", [secretHash])).flatMap { $0.map(invitation(from:)) }
    }

    /// The invitations still waiting for a device, the newest first.
    func openInvitations() -> [InvitationRecord] {
        ((try? database.query("SELECT * FROM invitations WHERE used_at IS NULL AND expires_at > ? ORDER BY created_at DESC", [Date()])) ?? [])
            .map(invitation(from:))
    }

    /// Spends an invitation on a new device, in one transaction: two devices racing with one link get one token.
    func redeemInvitation(id: Int, deviceName: String, tokenHash: String) throws -> Bool {
        try database.transaction {
            guard let row = try database.first("SELECT * FROM invitations WHERE id = ? AND used_at IS NULL AND expires_at > ?", [id, Date()]),
                  let userID = row.int("user_id") else { return false }
            try database.execute("UPDATE invitations SET used_at = ? WHERE id = ?", [Date(), id])
            _ = try addDevice(userID: userID, name: deviceName, kind: "app", tokenHash: tokenHash)
            return true
        }
    }

    func removeInvitation(id: Int) throws {
        try database.execute("DELETE FROM invitations WHERE id = ?", [id])
    }

    private func invitation(from row: Row) -> InvitationRecord {
        InvitationRecord(id: row.int("id") ?? 0, userID: row.int("user_id") ?? 0, createdAt: row.date("created_at") ?? Date(),
                         expiresAt: row.date("expires_at") ?? Date(), usedAt: row.date("used_at"))
    }
}
