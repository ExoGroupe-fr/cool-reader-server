import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open Library (Internet Archive): no key, every edition in every language, covers by id. It knows the books
/// Apple doesn't sell (older editions, web novels, BD albums); its synopses are mostly in English and live on
/// the work's own record, fetched only for the book that is applied. Only titles and authors are sent.
nonisolated enum OpenLibraryClient {
    private static let pacer = RequestPacer(interval: .seconds(1))
    private static let fields = "key,title,subtitle,author_name,first_publish_year,cover_i,language,subject,editions,editions.key,editions.title,editions.language,editions.cover_i"

    /// By title and author when they are known apart, else by free text (the « Associer… » search field).
    static func search(title: String? = nil, author: String? = nil, text: String? = nil, limit: Int = 10) async throws -> [BookMatch] {
        let language = MetadataLocale.language
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: fields),
            // The edition listed with each work is one in this language when there is one.
            URLQueryItem(name: "lang", value: language),
        ]
        if let title { items.append(URLQueryItem(name: "title", value: title)) }
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        if let text { items.append(URLQueryItem(name: "q", value: text)) }
        components.queryItems = items
        return parse(try await get(components.url!))
    }

    /// One result per work, plus its edition in the user's language when the title differs
    /// ("Twenty Thousand Leagues Under the Sea" and "Vingt mille lieues sous les mers").
    static func parse(_ data: Data) -> [BookMatch] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var matches: [BookMatch] = []
        for doc in json["docs"] as? [[String: Any]] ?? [] {
            guard let key = doc["key"] as? String, let title = (doc["title"] as? String).map(sentenceCased) else { continue }
            let authors = (doc["author_name"] as? [String] ?? []).map(nameCased)
            let year = doc["first_publish_year"] as? Int
            let genres = Self.genres(doc["subject"] as? [String] ?? [])
            let languages = (doc["language"] as? [String] ?? []).compactMap(languageCode)
            matches.append(BookMatch(source: .openLibrary, id: "ol:\(key)", title: title, subtitle: doc["subtitle"] as? String,
                                     authors: authors, year: year, releaseDate: nil, language: languages.count == 1 ? languages[0] : nil,
                                     summary: nil, genres: genres, coverURL: (doc["cover_i"] as? Int).map(coverURL)))
            let edition = ((doc["editions"] as? [String: Any])?["docs"] as? [[String: Any]])?.first
            if let edition, let editionKey = edition["key"] as? String, let editionTitle = (edition["title"] as? String).map(sentenceCased),
               FileNameParser.normalized(editionTitle) != FileNameParser.normalized(title) {
                let language = (edition["language"] as? [String])?.first.flatMap(languageCode)
                let cover = (edition["cover_i"] as? Int ?? doc["cover_i"] as? Int).map(coverURL)
                matches.append(BookMatch(source: .openLibrary, id: "ol:\(editionKey)", title: editionTitle, subtitle: nil,
                                         authors: authors, year: year, releaseDate: nil, language: language, summary: nil, genres: genres,
                                         coverURL: cover))
            }
        }
        return matches
    }

    /// A work or an edition by key ("/works/OL1W", "/books/OL1M"), for « Actualiser les métadonnées ».
    static func lookup(key: String) async throws -> BookMatch? {
        let json = try await record(key)
        guard let title = (json["title"] as? String).map(sentenceCased) else { return nil }
        return BookMatch(source: .openLibrary, id: "ol:\(key)", title: title, subtitle: json["subtitle"] as? String,
                         authors: [], year: (json["first_publish_date"] as? String).flatMap { Int($0.suffix(4)) },
                         releaseDate: nil, language: nil, summary: try await summary(of: json),
                         genres: genres(json["subjects"] as? [String] ?? []),
                         coverURL: (json["covers"] as? [Int])?.first { $0 > 0 }.map(coverURL))
    }

    /// The synopsis of a work or an edition; editions borrow their work's.
    static func summary(key: String) async throws -> String? {
        try await summary(of: try await record(key))
    }

    private static func summary(of json: [String: Any]) async throws -> String? {
        var json = json
        if json["description"] == nil, let work = (json["works"] as? [[String: Any]])?.first?["key"] as? String {
            json = try await record(work)
        }
        let description = json["description"] as? String ?? (json["description"] as? [String: Any])?["value"] as? String
        let text = description.map(MangaDexClient.cleanDescription)
        return text?.isEmpty == false ? text : nil
    }

    private static func record(_ key: String) async throws -> [String: Any] {
        let data = try await get(URL(string: "https://openlibrary.org\(key).json")!)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func coverURL(_ id: Int) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg")!
    }

    /// Open Library's subjects are free text, mostly English: the few that make a genre, in English.
    static func genres(_ subjects: [String]) -> [String] {
        let map: [(String, String)] = [
            ("science fiction", "Science fiction"), ("fantasy", "Fantasy"),
            ("romance", "Romance"), ("love stories", "Romance"),
            ("thriller", "Thriller"), ("suspense", "Thriller"),
            ("detective", "Mystery"), ("mystery", "Mystery"),
            ("horror", "Horror"), ("comic books", "Comics"), ("comics", "Comics"),
            ("bandes dessinees", "Comics"), ("graphic novels", "Comics"),
            ("young adult", "Young adult"), ("juvenile fiction", "Children"),
            ("children", "Children"), ("adventure", "Adventure"),
            ("humor", "Humor"), ("history", "History"),
            ("philosophy", "Philosophy"), ("psychology", "Psychology"),
            ("biography", "Biography"), ("education", "Education"),
            ("science", "Science"),
        ]
        var result: [String] = []
        for subject in subjects {
            let normalized = FileNameParser.normalized(subject)
            guard let genre = map.first(where: { normalized.contains($0.0) })?.1, !result.contains(genre) else { continue }
            result.append(genre)
            if result.count == 3 { break }
        }
        return result
    }

    /// Some records are in capitals, the way library catalogues used to type them:
    /// "L'ART DE LA GUERRE" → "L'art de la guerre".
    static func sentenceCased(_ text: String) -> String {
        guard isCapitals(text) else { return text }
        let lowered = text.lowercased()
        return lowered.prefix(1).uppercased() + lowered.dropFirst()
    }

    /// "DUPONT JEAN-PIERRE" → "Dupont Jean-Pierre".
    static func nameCased(_ name: String) -> String {
        guard isCapitals(name) else { return name }
        return name.lowercased().split(separator: " ").map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func isCapitals(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return letters.count >= 3 && letters == letters.uppercased()
    }

    private static func languageCode(_ code: String) -> String? {
        ["fre": "fr", "fra": "fr", "eng": "en", "spa": "es", "ger": "de", "deu": "de", "ita": "it", "jpn": "ja", "por": "pt"][code]
    }

    private static func get(_ url: URL) async throws -> Data {
        await pacer.wait()
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw BookCatalogError.http(service: "Open Library", status: status) }
        return data
    }
}
