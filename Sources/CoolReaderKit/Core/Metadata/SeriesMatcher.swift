import Foundation

/// What the matcher knows of a series from the library.
nonisolated struct SeriesMatchInput: Sendable {
    nonisolated struct Book: Sendable {
        /// Identifies the book in `SeriesMatch.bookCovers`.
        var key: String
        var fileName: String
        var number: Double?
        var format: BookFormat
    }

    var folderTitle: String
    var customTitle: String?
    var folderPath: String?
    var kind: UnitKind
    /// Authors already known from the files (ComicInfo.xml, .nfo).
    var authors: [String] = []
    /// In reading order.
    var books: [Book]
}

/// What the catalogues said about a series.
nonisolated struct SeriesMatch: Sendable, Codable, Equatable {
    enum Source: String, Sendable, Codable {
        case anilist, mangadex, appleBooks, openLibrary, comicVine, wikipedia
    }

    var source: Source
    var anilistID: Int?
    var mangadexID: String?
    /// "ab:…" for Apple Books, "ol:…" for Open Library.
    var catalogID: String?
    /// The title the catalogue gives, close to the folder's; nil keeps the folder's.
    var title: String?
    var summary: String?
    /// Where the synopsis comes from when it isn't `source`: Wikipedia's page of the series.
    var summarySource: Source?
    var summaryURL: URL?
    var authors: [String] = []
    var genres: [String] = []
    var year: Int?
    /// finished, ongoing, upcoming, cancelled or hiatus.
    var status: String?
    var averageScore: Int?
    var originalLanguage: String?
    var coverURL: URL?
    var bannerURL: URL?
    /// Covers of single volumes, by book key.
    var bookCovers: [String: URL] = [:]
}

/// The app's metadata agent without its database: manga from AniList then MangaDex, books (novels, essays, BD)
/// from Apple Books then Open Library. The caller runs one series at a time, with a pause in between.
nonisolated enum SeriesMatcher {
    /// nil when nothing is convincing enough to apply without asking; throws when the catalogues can't be
    /// reached, so that the series is tried again later.
    static func match(_ series: SeriesMatchInput) async throws -> SeriesMatch? {
        let query = series.folderTitle
        // Novels come as EPUB, manga and BD as archives or PDF. Books are looked up first for EPUBs: AniList would
        // pair a short novel title ("Germinal") with an unrelated manga, and Apple Books has light novels too.
        let booksFirst = series.books.allSatisfy { $0.format == .epub }
        // Comics in issues ("Saga #12") are Comic Vine's first, when the admin gave a key.
        if series.kind == .issue, let match = await matchComicVine(series) { return match }
        if booksFirst, let match = try await matchBooks(series) { return match }
        var media = try await bestAniList(for: query, series: series)
        if media == nil, let variant = TitleMatcher.spellingVariant(query) {
            media = try await bestAniList(for: variant, series: series, scoredAgainst: query)
        }
        if let media {
            return await apply(media, to: series)
        }
        // MangaDex alone knows comics only: an EPUB novel would get the cover of its manga adaptation.
        if !booksFirst, let manga = try await bestMangaDex(for: query) {
            if let id = manga.aniListID, let media = try? await AniListClient.media(id: id) {
                return await apply(media, to: series, mangaDex: manga)
            }
            return await applyMangaDexOnly(manga, to: series)
        }
        if !booksFirst, let match = try await matchBooks(series) { return match }
        if !booksFirst, series.kind != .issue, let match = await matchComicVine(series) { return match }
        // What no store sells, a series of BD or comics in a folder of its own, may still have its article.
        if series.books.count > 1 || series.folderPath != nil, let page = try? await WikipediaClient.seriesSummary(
            [seriesTitle(for: series).title], authors: series.authors, languages: [MetadataLocale.language, "en"]) {
            return applyWikipedia(page, to: series)
        }
        return nil
    }

    /// A comic on Comic Vine: its synopsis (in English, so Wikipedia's in the server's language when it has one), its
    /// cover, and each issue's. Never a reason to stop matching: a wrong key or a Comic Vine down only skip it.
    private static func matchComicVine(_ series: SeriesMatchInput) async -> SeriesMatch? {
        guard ComicVineClient.key != nil else { return nil }
        let title = seriesTitle(for: series).title
        guard let results = try? await ComicVineClient.searchVolumes(title),
              let volume = ComicVineClient.best(results, for: title, highestNumber: series.books.compactMap(\.number).max()) else { return nil }
        return await applyComicVine(volume, to: series)
    }

    static func applyComicVine(_ volume: ComicVineClient.Volume, to series: SeriesMatchInput) async -> SeriesMatch {
        var match = SeriesMatch(source: .comicVine)
        match.catalogID = "cv:\(volume.id)"
        match.title = TitleMatcher.similarity(volume.name, series.folderTitle) >= 0.75 ? volume.name : nil
        match.summary = volume.summary
        match.year = volume.startYear
        match.authors = series.authors
        match.coverURL = volume.coverURL
        // Issues have numbers of their own; a trade paperback's "Vol. 2" isn't issue #2.
        if series.kind == .issue, let covers = try? await ComicVineClient.issueCovers(volumeID: volume.id) {
            for book in series.books {
                if let number = book.number, let url = covers[number] { match.bookCovers[book.key] = url }
            }
        }
        if MetadataLocale.language != "en" { await preferWikipediaSummary(&match, series: series) }
        return match
    }

    static func applyWikipedia(_ page: WikipediaClient.Summary, to series: SeriesMatchInput) -> SeriesMatch {
        var match = SeriesMatch(source: .wikipedia)
        let title = WikipediaClient.withoutQualifier(page.title)
        match.title = TitleMatcher.similarity(title, series.folderTitle) >= 0.85 ? title : nil
        match.summary = page.extract
        match.summarySource = .wikipedia
        match.summaryURL = page.url
        match.authors = series.authors
        return match
    }

    /// The series' own synopsis, in the server's language, instead of a volume's (a store's) or an English one
    /// (AniList's): Wikipedia's when it has a page for the series.
    private static func preferWikipediaSummary(_ match: inout SeriesMatch, series: SeriesMatchInput, titles: [String] = []) async {
        let names = [match.title ?? seriesTitle(for: series).title] + titles
        guard let page = try? await WikipediaClient.seriesSummary(names, authors: match.authors, languages: [MetadataLocale.language])
        else { return }
        match.summary = page.extract
        match.summarySource = .wikipedia
        match.summaryURL = page.url
    }

    // MARK: - Manga

    private static func bestAniList(for query: String, series: SeriesMatchInput, scoredAgainst original: String? = nil) async throws -> AniListMedia? {
        let results = try await AniListClient.search(query, limit: 8)
        return results
            .compactMap { media in
                TitleMatcher.rank(media, query: original ?? query, localCount: series.books.count, kind: series.kind).map { (media, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    private static func bestMangaDex(for query: String) async throws -> MangaDexClient.Manga? {
        let results = try await MangaDexClient.search(query).filter { !$0.isFanEdition }
        return results
            .map { ($0, TitleMatcher.best(query, among: $0.titles).score) }
            .filter { $0.1 >= 0.9 }
            .max { $0.1 < $1.1 }?.0
    }

    static func apply(_ media: AniListMedia, to series: SeriesMatchInput, mangaDex: MangaDexClient.Manga? = nil) async -> SeriesMatch {
        var match = SeriesMatch(source: .anilist)
        match.anilistID = media.id
        match.originalLanguage = media.originalLanguage
        match.title = preferredTitle(among: media.allTitles, fallback: media.title.english ?? media.title.romaji, folderTitle: series.folderTitle)
        match.summary = media.cleanDescription
        match.authors = series.authors.isEmpty ? media.authors : series.authors
        match.genres = media.localizedGenres
        match.year = media.startDate?.year
        match.status = media.localizedStatus
        match.averageScore = media.averageScore
        match.coverURL = media.coverURL
        match.bannerURL = media.bannerURL
        var manga = mangaDex
        if manga == nil { manga = await findMangaDex(for: media, title: match.title) }
        if let manga { await enrich(&match, series: series, with: manga) }
        if MetadataLocale.language != "en", manga?.localizedDescription == nil {
            await preferWikipediaSummary(&match, series: series, titles: media.allTitles)
        }
        return match
    }

    /// The MangaDex entry linked to this AniList entry. Never guessed from the title alone: a wrong entry
    /// would show the covers of another series.
    private static func findMangaDex(for media: AniListMedia, title: String?) async -> MangaDexClient.Manga? {
        var queries: [String] = []
        for title in [title, media.title.english, media.title.romaji] {
            if let title, !queries.contains(title) { queries.append(title) }
        }
        for query in queries {
            guard let results = try? await MangaDexClient.search(query) else { continue }
            if let match = results.first(where: { $0.aniListID == media.id }) { return match }
        }
        return nil
    }

    private static func enrich(_ match: inout SeriesMatch, series: SeriesMatchInput, with manga: MangaDexClient.Manga) async {
        match.mangadexID = manga.id
        if let synopsis = manga.localizedDescription { match.summary = synopsis }
        if series.kind == .volume, let covers = try? await MangaDexClient.volumeCovers(mangaID: manga.id) {
            let preferred = MangaDexClient.preferredCovers(covers)
            for book in series.books {
                if let number = book.number, let url = preferred[number] { match.bookCovers[book.key] = url }
            }
        }
    }

    private static func applyMangaDexOnly(_ manga: MangaDexClient.Manga, to series: SeriesMatchInput) async -> SeriesMatch {
        var match = SeriesMatch(source: .mangadex)
        match.originalLanguage = manga.originalLanguage
        match.title = preferredTitle(among: manga.titles, fallback: manga.mainTitle, folderTitle: series.folderTitle)
        match.summary = manga.bestDescription
        match.authors = series.authors.isEmpty ? manga.authors : series.authors
        match.genres = manga.genres
        match.year = manga.year
        match.status = manga.localizedStatus
        match.coverURL = manga.coverURL
        await enrich(&match, series: series, with: manga)
        return match
    }

    private static func preferredTitle(among titles: [String], fallback: String?, folderTitle: String) -> String {
        let best = TitleMatcher.best(folderTitle, among: titles)
        if best.score >= 0.75, let title = best.title { return FileNameParser.displayTitle(fromFolderName: title) }
        return fallback ?? folderTitle
    }

    // MARK: - Books

    /// Novels, essays and BD: Apple Books, then Open Library for what Apple doesn't sell. nil when nothing is
    /// convincing enough to apply without asking.
    private static func matchBooks(_ series: SeriesMatchInput) async throws -> SeriesMatch? {
        let books = series.books
        let query = bookQuery(for: series)
        let language = MetadataLocale.language
        guard books.count > 1 else {
            // The file's name first, then its folder's: "Watchmen/WATCHMEN - Les Gardiens - Intégrale.cbr".
            for query in [query] + folderQuery(for: series, besides: query) {
                for search in searches(for: query) {
                    let results = search.source == .appleBooks
                        ? try await AppleBooksClient.search(search.term ?? query.searchText)
                        : try await OpenLibraryClient.search(title: query.searchTitle, author: query.author)
                    guard let found = BookMatcher.best(results, for: query, language: language) else { continue }
                    return await applyBook(found, to: series)
                }
            }
            return nil
        }
        // A series of several books: one search for the series, each volume found in it by its own title or number,
        // then a search for each volume with a title of its own that the first one missed. Chapters and episodes
        // aren't sold one by one, and their numbers aren't the books': the series alone is looked up.
        var seriesQuery = query
        seriesQuery.number = 1
        let byVolume = series.kind != .chapter
        for search in searches(for: query) {
            let pool = search.source == .appleBooks
                ? try await AppleBooksClient.search(search.term ?? query.searchText, limit: 50)
                : try await OpenLibraryClient.search(title: query.searchTitle, author: query.author, limit: 30)
            let volumes = byVolume ? try await volumeMatches(for: series, pool: pool, searchesMissing: false) : [:]
            // The series takes its first volume's book, or a result naming the series itself.
            guard let lead = books.lazy.compactMap({ volumes[$0.key] }).first
                    ?? BookMatcher.best(pool, for: seriesQuery, language: language, series: true) else { continue }
            let complete = byVolume && search.source == .appleBooks ? try await volumeMatches(for: series, pool: pool) : volumes
            return await applyBook(lead, to: series, volumes: complete)
        }
        return nil
    }

    /// The volumes of a series in catalogue results. Volumes with a title of their own that the series search
    /// missed get a search each, a dozen at most.
    private static func volumeMatches(for series: SeriesMatchInput, pool: [BookMatch], searchesMissing: Bool = true) async throws -> [String: BookMatch] {
        guard series.books.count > 1 else { return [:] }
        let query = bookQuery(for: series)
        let volumes = series.books.map { (key: $0.key, query: volumeQuery(for: $0, series: query)) }
        var found = BookMatcher.withoutSharedBooks(
            BookMatcher.volumes(volumes, in: pool, series: query, language: MetadataLocale.language), volumes: volumes)
        guard searchesMissing else { return found }
        let missing = volumes.filter { found[$0.key] == nil && TitleMatcher.similarity($0.query.title, query.title) < 0.9 }
        for volume in missing.prefix(12) {
            let results = try await AppleBooksClient.search(volume.query.searchText, limit: 10)
            found[volume.key] = BookMatcher.volumes([volume], in: results, series: query, language: MetadataLocale.language)[volume.key]
        }
        return BookMatcher.withoutSharedBooks(found, volumes: volumes)
    }

    static func applyBook(_ book: BookMatch, to series: SeriesMatchInput, volumes: [String: BookMatch] = [:]) async -> SeriesMatch {
        var match = SeriesMatch(source: book.source == .appleBooks ? .appleBooks : .openLibrary)
        var summary = book.summary
        if summary == nil, book.source == .openLibrary {
            summary = try? await OpenLibraryClient.summary(key: String(book.id.dropFirst(3)))
        }
        match.catalogID = book.id
        if series.books.count > 1 || series.kind != .book {
            // A volume's title is no name for the series, even when the folder holds a single volume ("Blacksad 01"):
            // the catalogue's series name, or the folder's.
            let name = seriesTitle(for: series)
            if let catalogName = book.seriesName, TitleMatcher.similarity(catalogName, name.title) >= 0.75 {
                match.title = catalogName
            } else {
                match.title = name.fromParentFolder ? name.title : nil
            }
        } else {
            match.title = book.displayTitle
        }
        match.summary = summary
        if series.authors.isEmpty {
            // Store listings may name the translator first: the author from the file names leads.
            let wanted = bookQuery(for: series).author
            let isWanted = { (name: String) in wanted.map { BookMatcher.authorMatches($0, among: [name]) } ?? false }
            match.authors = book.authors.filter(isWanted) + book.authors.filter { !isWanted($0) }
        } else {
            match.authors = series.authors
        }
        match.genres = book.genres
        match.year = book.year
        match.coverURL = book.coverURL
        if series.books.count == 1, let first = series.books.first {
            // The cover of another volume ("Tome 7" for a "Blacksad 01") stays the series', not the book's; so does an
            // edition's for a chapter, which keeps the cover of its own pages.
            if series.kind != .chapter, book.number == nil || first.number == nil || book.number == first.number {
                match.bookCovers[first.key] = book.coverURL
            }
        } else {
            for item in series.books { match.bookCovers[item.key] = volumes[item.key]?.coverURL }
        }
        // A series of volumes gets the series' synopsis rather than one volume's.
        if series.books.count > 1 || series.kind != .book { await preferWikipediaSummary(&match, series: series) }
        return match
    }

    /// What to search a series by. A single book: its file name, which often holds the author
    /// ("Les Misérables - Victor Hugo.epub"). Several: the series' name and the author they share.
    /// A misspelt author in a file name ("Jules Vernes") can hide the book: then the title alone, the author still
    /// checked by the ranking.
    private static func searches(for query: BookQuery) -> [(source: BookMatch.Source, term: String?)] {
        [(.appleBooks, nil)] + (query.author != nil ? [(.appleBooks, query.searchTitle)] : []) + [(.openLibrary, nil)]
    }

    static func bookQuery(for series: SeriesMatchInput) -> BookQuery {
        let books = series.books
        if books.count == 1, let book = books.first {
            var query = BookQuery.parse(baseName(of: book))
            if query.author == nil { query.author = series.authors.first }
            // "WATCHMEN - Les Gardiens - Intégrale": an edition's words aren't the book's title, as for a series.
            query.title = withoutEditionWords(query.title)
            return query
        }
        let authors = books.compactMap { BookQuery.parse(baseName(of: $0)).author }
        let common = Dictionary(grouping: authors, by: FileNameParser.normalized).values.max { $0.count < $1.count }
        let shared = common.flatMap { $0.count * 2 >= books.count ? $0.first : nil }
        return BookQuery(title: seriesTitle(for: series).title, author: series.authors.first ?? shared)
    }

    /// One volume of a series: its file name, and its number from the library.
    static func volumeQuery(for book: SeriesMatchInput.Book, series: BookQuery) -> BookQuery {
        var query = BookQuery.parse(baseName(of: book))
        if query.author == nil { query.author = series.author }
        if let number = book.number {
            if query.number == nil, let last = query.title.split(separator: " ").last, Double(last) == number {
                // "DRAGON BALL 12": a bare number at the end is the volume's, not the title's.
                query.title = query.title.split(separator: " ").dropLast().joined(separator: " ")
            }
            query.number = number
            query.hasVolumeMarker = true
        }
        return query
    }

    /// The name of a series for catalogues: "Les Misérables Intégrale/Français" → "Les Misérables".
    static func seriesTitle(for series: SeriesMatchInput) -> (title: String, fromParentFolder: Bool) {
        // Folder names on disk are often decomposed ("e" + accent): compose them for the patterns below.
        var name = (series.customTitle ?? series.folderTitle).precomposedStringWithCanonicalMapping
        var fromParent = false
        let languages: Set<String> = ["francais", "french", "fr", "vf", "anglais", "english", "en", "vo", "espagnol",
                                      "spanish", "allemand", "german", "italien", "italian"]
        if languages.contains(FileNameParser.normalized(name)), let path = series.folderPath {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty {
                name = FileNameParser.displayTitle(fromFolderName: parent.precomposedStringWithCanonicalMapping)
                fromParent = true
            }
        }
        return (withoutEditionWords(name), fromParent)
    }

    /// The folder's name, for a book alone in its folder whose file name says something else. Nothing for a loose
    /// file, whose series is named after it.
    static func folderQuery(for series: SeriesMatchInput, besides query: BookQuery) -> [BookQuery] {
        guard series.folderPath != nil else { return [] }
        let title = seriesTitle(for: series).title
        guard FileNameParser.normalized(title) != FileNameParser.normalized(query.title) else { return [] }
        return [BookQuery(title: title, author: query.author)]
    }

    /// "Les Misérables Intégrale", "Saga Les Rougon-Macquart", "Astérix - Collection complète" → the title alone.
    static func withoutEditionWords(_ name: String) -> String {
        let noise = #"(?i)\b(?:int[ée]grale|saga|collection|compl[eè]te?|coffret|cycle|the complete|box set|tomes?\s*\d+\s*(?:à|a|-|to)\s*\d+)\b"#
        let cleaned = name.replacingOccurrences(of: noise, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -,:"))
        return cleaned.isEmpty ? name : cleaned
    }

    private static func baseName(of book: SeriesMatchInput.Book) -> String {
        (book.fileName as NSString).deletingPathExtension
    }
}
