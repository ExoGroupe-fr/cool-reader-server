import Foundation

/// One book file found in a library.
nonisolated struct ScannedBook: Sendable, Equatable {
    /// Path relative to the library's folder.
    var relativePath: String
    var fileName: String
    var format: BookFormat
    var fileSize: Int64
    var modifiedAt: Date?
    /// Relative path of the folder holding the file ("" for the library's own folder).
    var folder: String
}

/// Artwork and notes found in a folder.
nonisolated struct ScannedFolder: Sendable, Equatable {
    var relativePath: String
    var bannerPath: String?
    var posterPath: String?
    var nfoPath: String?
}

nonisolated struct ScanResult: Sendable {
    var books: [ScannedBook] = []
    var folders: [String: ScannedFolder] = [:]
    /// Folders that couldn't be listed (relative paths): the books known inside them are kept.
    var unreadableFolders: [String] = []

    /// True for a path inside a folder that couldn't be listed ("" stands for the whole library).
    func isInUnreadableFolder(_ relativePath: String) -> Bool {
        unreadableFolders.contains { $0.isEmpty || relativePath == $0 || relativePath.hasPrefix($0 + "/") }
    }
}

nonisolated struct BookDraft: Sendable, Equatable {
    var scanned: ScannedBook
    var number: Double?
    /// The book's own title, when its name has one beside its number ("Tome 1 - La catastrophe").
    var extraTitle: String?
    /// Its name without extension, for books without a number.
    var plainName: String
}

nonisolated struct SeriesDraft: Sendable, Equatable {
    /// Stable identity inside its library: the folder path, or the normalised name for loose files.
    var key: String
    var title: String
    var folderPath: String?
    var kind: UnitKind
    var books: [BookDraft]
    var bannerPath: String?
    var posterPath: String?
    var nfoPath: String?
}

/// Books into series, the way the app groups them: a folder is a series at any depth, or the folder above it
/// when it only holds one volume; loose files form series by the name they share.
nonisolated enum SeriesGrouper {
    static func group(_ scan: ScanResult) -> [SeriesDraft] {
        var groups: [String: (title: String, folder: String?, books: [ScannedBook])] = [:]
        var order: [String] = []

        for book in scan.books {
            let key: String
            let title: String
            var folder: String?
            if book.folder.isEmpty {
                let parsed = FileNameParser.parse(book.fileName)
                let name = parsed.seriesName ?? cleanName(book.fileName)
                key = "name:" + FileNameParser.normalized(name)
                title = FileNameParser.displayTitle(fromFolderName: name)
            } else {
                let seriesPath = seriesFolder(for: book.folder)
                key = "folder:" + seriesPath
                title = FileNameParser.displayTitle(fromFolderName: (seriesPath as NSString).lastPathComponent)
                folder = seriesPath
            }
            if groups[key] == nil {
                groups[key] = (title, folder, [])
                order.append(key)
            }
            groups[key]?.books.append(book)
        }

        return order.compactMap { key -> SeriesDraft? in
            guard let group = groups[key] else { return nil }
            let hint = group.folder.map { ($0 as NSString).lastPathComponent }
            let parsed = group.books.map { book in (book, FileNameParser.parse(book.fileName, seriesHint: hint ?? group.title)) }
            let kind = inferKind(parsed.map(\.1), count: group.books.count)
            var drafts = parsed.map { book, info -> BookDraft in
                BookDraft(scanned: book, number: kind == .book ? nil : info.number, extraTitle: info.extraTitle,
                          plainName: cleanName(book.fileName))
            }
            drafts.sort { a, b in
                switch (a.number, b.number) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return NaturalOrder.less(a.scanned.fileName, b.scanned.fileName)
                }
            }
            let folderInfo = group.folder.flatMap { scan.folders[$0] }
            // Every file names the same series ("… - Harry Potter [Tome 3] - …"): it beats a folder called
            // « Français ». The key stays the folder's, so nothing moves.
            let named = Set(parsed.map(\.1.namedSeries))
            let title = named.count == 1 ? named.first.flatMap { $0 } ?? group.title : group.title
            return SeriesDraft(key: key, title: title, folderPath: group.folder, kind: kind, books: drafts,
                               bannerPath: folderInfo?.bannerPath, posterPath: folderInfo?.posterPath, nfoPath: folderInfo?.nfoPath)
        }
    }

    /// The folder a series is named after: the book's folder, at any depth ("Shōnen/Dragon Ball"), or the
    /// one above when the book's folder only holds a volume ("Dragon Ball/Tome 03", "Dragon Ball/Dragon Ball T03").
    static func seriesFolder(for folder: String) -> String {
        let parent = (folder as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return folder }
        let parentName = (parent as NSString).lastPathComponent
        let parsed = FileNameParser.parse((folder as NSString).lastPathComponent, seriesHint: parentName, hasExtension: false)
        // A year-like name ("1984") is a title, not a volume.
        guard let number = parsed.number, number < 1000 else { return folder }
        // "Tome 1 - La catastrophe" is still a volume; a bare number must stand alone ("20th Century Boys").
        guard parsed.kind != nil || parsed.extraTitle == nil else { return folder }
        if let series = parsed.seriesName, FileNameParser.normalized(series) != FileNameParser.normalized(parentName) {
            return folder
        }
        return parent
    }

    static func inferKind(_ parsed: [ParsedFileName], count: Int) -> UnitKind {
        let kinds = parsed.compactMap(\.kind)
        if kinds.contains(.chapter) { return .chapter }
        if kinds.contains(.volume) { return .volume }
        if kinds.contains(.issue) { return .issue }
        let numbered = parsed.filter { $0.number != nil }.count
        if numbered == 0 { return .book }
        return count > 60 ? .chapter : .volume
    }

    static func cleanName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
