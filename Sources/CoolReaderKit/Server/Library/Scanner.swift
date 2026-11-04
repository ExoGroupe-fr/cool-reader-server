import Foundation

/// Walks a library's folder: names, sizes and dates. The files themselves are read by the analysis after, and
/// only when they are new or changed.
nonisolated enum FolderWalker {
    /// macOS, Windows and NAS bookkeeping: Synology's thumbnails (@eaDir), recycle bins, snapshots.
    static let ignoredFolderNames: Set<String> = ["__MACOSX", ".Trash", "@eaDir", "#recycle", "#snapshot", "$RECYCLE.BIN",
                                                  "System Volume Information", "lost+found", ".covers"]
    private static let bannerNames = ["entête", "entete", "en-tête", "header", "banner", "bannière", "banniere", "fanart", "backdrop", "background"]
    private static let posterNames = ["cover", "poster", "folder", "couverture", "affiche"]

    /// nil when the folder can't be listed (unplugged drive, missing mount): a failed scan never empties a library.
    static func scan(root: URL) -> ScanResult? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let rootPath = root.standardizedFileURL.path
        var result = ScanResult()
        var unreadable: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { url, _ in
                                                                  unreadable.insert(relativePath(of: url, rootPath: rootPath))
                                                                  return true
                                                              }) else { return nil }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            if name.hasPrefix(".") || (isDirectory && ignoredFolderNames.contains(name)) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard !isDirectory else { continue }
            let relative = relativePath(of: url, rootPath: rootPath)
            let folder = (relative as NSString).deletingLastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            if let format = BookFormat(fileExtension: ext) {
                result.books.append(ScannedBook(relativePath: relative, fileName: name, format: format,
                                                fileSize: Int64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate,
                                                folder: folder))
            } else if BookFormat.isImage(name) {
                let base = (name as NSString).deletingPathExtension.lowercased()
                var info = result.folders[folder] ?? ScannedFolder(relativePath: folder)
                if bannerNames.contains(where: { base.contains($0) }) {
                    info.bannerPath = info.bannerPath ?? relative
                } else if posterNames.contains(where: { base == $0 || base.hasPrefix($0) }) {
                    info.posterPath = info.posterPath ?? relative
                }
                result.folders[folder] = info
            } else if ext == "nfo" {
                result.folders[folder, default: ScannedFolder(relativePath: folder)].nfoPath = relative
            }
        }
        result.unreadableFolders = unreadable.sorted()
        return result
    }

    private static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Scans the libraries, one at a time: walk, analyse the new and changed books four at a time, write.
actor LibraryScanner {
    private let store: Store
    private let onScanned: @Sendable () -> Void
    private(set) var scanning: Set<Int> = []
    private var queued: [Int] = []

    init(store: Store, onScanned: @escaping @Sendable () -> Void) {
        self.store = store
        self.onScanned = onScanned
    }

    var isScanning: Bool { !scanning.isEmpty || !queued.isEmpty }

    func scanAll() {
        for library in store.libraries() { enqueue(library.id) }
    }

    /// Scans a library and returns when it is done (tests, and the first start of the Mac app).
    func scanNow(_ libraryID: Int) async {
        scanning.insert(libraryID)
        await scan(libraryID: libraryID)
        scanning.remove(libraryID)
    }

    func enqueue(_ libraryID: Int) {
        guard !queued.contains(libraryID), !scanning.contains(libraryID) else { return }
        queued.append(libraryID)
        if scanning.isEmpty { Task { await drain() } }
    }

    private func drain() async {
        while !queued.isEmpty {
            let id = queued.removeFirst()
            scanning.insert(id)
            await scan(libraryID: id)
            scanning.remove(id)
        }
        onScanned()
    }

    private func scan(libraryID: Int) async {
        guard let library = store.library(id: libraryID) else { return }
        let root = URL(fileURLWithPath: library.path, isDirectory: true)
        let started = Date()
        guard let result = FolderWalker.scan(root: root) else {
            Log.warning("Library « \(library.name) »: \(library.path) can't be read; its books are kept.")
            try? store.setScanned(libraryID: libraryID, error: "unreachable")
            return
        }
        let known = store.knownBooks(libraryID: libraryID)
        let toAnalyse = result.books.filter { book in
            guard let stored = known[book.relativePath], stored.analysed else { return true }
            return stored.size != book.fileSize || stored.modified != book.modifiedAt?.timeIntervalSince1970
        }
        let analyses = await Self.analyse(toAnalyse, root: root)
        var nfo: [String: NFOInfo] = [:]
        for folder in result.folders.values {
            guard let path = folder.nfoPath, let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { continue }
            nfo[path] = NFOParser.parse(data)
        }
        do {
            let added = try store.applyScan(libraryID: libraryID, drafts: SeriesGrouper.group(result), nfo: nfo, books: analyses,
                                            result: result)
            try store.setScanned(libraryID: libraryID, error: nil)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            Log.info("Library « \(library.name) »: \(result.books.count) books, \(added) new, \(toAnalyse.count) read, in \(seconds) s.")
        } catch {
            Log.error("Library « \(library.name) »: the scan couldn't be saved (\(error)).")
            try? store.setScanned(libraryID: libraryID, error: "\(error)")
        }
    }

    private static func analyse(_ books: [ScannedBook], root: URL) async -> [String: BookScan] {
        await withTaskGroup(of: (String, BookScan).self) { group in
            var results: [String: BookScan] = [:]
            var pending = books[...]
            func addNext() {
                guard let book = pending.popFirst() else { return }
                group.addTask {
                    let url = root.appendingPathComponent(book.relativePath)
                    do {
                        return (book.relativePath, .analysed(try BookAnalysis.analyze(url: url, format: book.format)))
                    } catch {
                        Log.warning("\(book.relativePath) can't be read (\(error)).")
                        return (book.relativePath, .failed("\(error)"))
                    }
                }
            }
            for _ in 0..<4 { addNext() }
            for await (path, scan) in group {
                results[path] = scan
                addNext()
            }
            return results
        }
    }
}

/// Looks the series up in the catalogues, one at a time with a pause in between, like the app. When the
/// catalogues can't be reached, it stops and tries again at the next scan.
actor MetadataAgent {
    private let store: Store
    private let isEnabled: Bool
    private var isRunning = false

    init(store: Store, isEnabled: Bool) {
        self.store = store
        self.isEnabled = isEnabled
    }

    /// What the matcher knows of a series: its folder, the admin's title, its kind, its authors from the .nfo or the
    /// first book's ComicInfo, and its books.
    static func input(for series: SeriesRecord, books: [BookRecord]) -> SeriesMatchInput {
        let authors = series.nfo?.authors.isEmpty == false ? series.nfo!.authors : (books.first?.metadata?.writers ?? [])
        return SeriesMatchInput(folderTitle: series.folderTitle, customTitle: series.customTitle, folderPath: series.folderPath,
                                kind: series.kind, authors: authors,
                                books: books.map { .init(key: String($0.id), fileName: $0.fileName, number: $0.number, format: $0.format) })
    }

    func wake() {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        Task { await run() }
    }

    private func run() async {
        defer { isRunning = false }
        while let id = store.pendingSeries(limit: 1).first, let series = store.series(id: id) {
            let input = Self.input(for: series, books: store.books(seriesID: id))
            do {
                let match = try await SeriesMatcher.match(input)
                // The admin may have chosen a match while the catalogues were asked: theirs stays.
                try store.setMatch(seriesID: id, status: match == nil ? "unmatched" : "matched", match: match, onlyIfPending: true)
                Log.info("« \(series.folderTitle) »: \(match.map { "matched on \($0.source.rawValue)" } ?? "no convincing match").")
            } catch {
                Log.warning("The catalogues can't be reached (\(error)); matching resumes at the next scan.")
                return
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }
}

nonisolated enum Log {
    static func info(_ message: String) { write("info", message) }
    static func warning(_ message: String) { write("warning", message) }
    static func error(_ message: String) { write("error", message) }

    /// Straight to the standard output, unbuffered: `docker logs` shows each line as it comes.
    private static func write(_ level: String, _ message: String) {
        let time = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data("\(time) [\(level)] \(message)\n".utf8))
    }
}
