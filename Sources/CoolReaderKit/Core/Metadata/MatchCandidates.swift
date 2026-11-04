import Foundation

/// A catalogue entry the admin may choose for a series the matcher got wrong, or didn't find: what tells it apart
/// (its kind, year, authors, cover) and the id that brings it back.
nonisolated struct MatchCandidate: Sendable, Codable, Equatable {
    var source: SeriesMatch.Source
    /// AniList's number, "ab:<Apple Books id>", "ol:<Open Library key>", "cv:<Comic Vine id>" or "<language>:<article>".
    var id: String
    var title: String
    /// "Manga · Katsuhiro Otomo", "Glénat · René Goscinny", in the catalogue's words.
    var detail: String?
    var year: Int?
    var coverURL: URL?
    var summary: String?
}

extension SeriesMatcher {
    /// What every catalogue finds for the admin's own search, best first in each: AniList for manga, Apple Books and
    /// Open Library for books and BD, Comic Vine for comics when there is a key, Wikipedia for a series' article. A
    /// catalogue that doesn't answer is left out.
    static func candidates(for query: String) async -> [MatchCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var found: [MatchCandidate] = []
        if let media = try? await AniListClient.search(text, limit: 6) {
            found += media.map { media in
                let kind = media.format.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
                return MatchCandidate(source: .anilist, id: String(media.id), title: media.title.english ?? media.title.romaji ?? text,
                                      detail: ([kind] + media.authors.prefix(2).map { Optional($0) }).compactMap { $0 }.joined(separator: " · "),
                                      year: media.startDate?.year, coverURL: media.coverURL, summary: media.cleanDescription)
            }
        }
        if let books = try? await AppleBooksClient.search(text, limit: 12) {
            found += books.map { candidate($0) }
        }
        if let books = try? await OpenLibraryClient.search(title: text, limit: 6) {
            found += books.map { candidate($0) }
        }
        if ComicVineClient.key != nil, let volumes = try? await ComicVineClient.searchVolumes(text) {
            found += volumes.map { volume in
                MatchCandidate(source: .comicVine, id: "cv:\(volume.id)", title: volume.name,
                               detail: [volume.publisher, "\(volume.issueCount) issues"].compactMap { $0 }.joined(separator: " · "),
                               year: volume.startYear, coverURL: volume.coverURL, summary: volume.summary)
            }
        }
        for language in [MetadataLocale.language, "en"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } {
            guard let titles = try? await WikipediaClient.search(text, language: language) else { continue }
            for title in titles.prefix(3) {
                guard let page = try? await WikipediaClient.summary(of: title, language: language),
                      WikipediaClient.isAboutSeries(page, authors: []) else { continue }
                found.append(MatchCandidate(source: .wikipedia, id: "\(language):\(page.title)", title: page.title, detail: page.description,
                                            year: nil, coverURL: nil, summary: page.extract))
            }
            if found.contains(where: { $0.source == .wikipedia }) { break }
        }
        return found
    }

    private static func candidate(_ book: BookMatch) -> MatchCandidate {
        MatchCandidate(source: book.source == .appleBooks ? .appleBooks : .openLibrary, id: book.id, title: book.title,
                       detail: book.authors.prefix(3).joined(separator: ", "), year: book.year, coverURL: book.coverURL, summary: book.summary)
    }

    /// The match a candidate gives the series, as the matcher would have made it; nil when the catalogue no longer
    /// has it.
    static func apply(candidate id: String, source: SeriesMatch.Source, to series: SeriesMatchInput) async throws -> SeriesMatch? {
        switch source {
        case .anilist:
            guard let number = Int(id) else { return nil }
            return await apply(try await AniListClient.media(id: number), to: series)
        case .appleBooks:
            guard let book = try await AppleBooksClient.lookup(id: String(id.dropFirst(3))) else { return nil }
            return await applyBook(book, to: series)
        case .openLibrary:
            guard let book = try await OpenLibraryClient.lookup(key: String(id.dropFirst(3))) else { return nil }
            return await applyBook(book, to: series)
        case .comicVine:
            guard let number = Int(id.dropFirst(3)), let volume = try await ComicVineClient.volume(id: number) else { return nil }
            return await applyComicVine(volume, to: series)
        case .wikipedia:
            guard let colon = id.firstIndex(of: ":") else { return nil }
            guard let page = try await WikipediaClient.summary(of: String(id[id.index(after: colon)...]), language: String(id[..<colon]))
            else { return nil }
            return applyWikipedia(page, to: series)
        case .mangadex:
            return nil
        }
    }
}
