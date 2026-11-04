import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wikipedia, for what the stores don't say: a series' own synopsis, in the server's language. The stores sell
/// volumes, and each one's text speaks of that volume ("Dans cet album…"); Wikipedia's page is the series'. Its texts
/// are under CC BY-SA: the pages that show one say where it comes from, with a link. Only series titles are sent.
nonisolated enum WikipediaClient {
    nonisolated struct Summary: Sendable, Equatable {
        var title: String
        /// The page's short description: "série française de bandes dessinées".
        var description: String?
        var extract: String
        var url: URL?
        var language: String
    }

    private static let pacer = RequestPacer(interval: .seconds(1))

    /// The page of a series in the first of `languages` that has one: among what a search for its titles finds, an
    /// article named like one of them that says it is a series of BD, comics, manga or novels, by its authors when
    /// they are known. A manga's titles help: French Wikipedia calls « Black Jack ni Yoroshiku » « Say Hello to Black
    /// Jack ».
    static func seriesSummary(_ titles: [String], authors: [String] = [], languages: [String]) async throws -> Summary? {
        var names: [String] = []
        for title in titles where !title.isEmpty && !names.contains(where: { FileNameParser.normalized($0) == FileNameParser.normalized(title) }) {
            names.append(title)
        }
        guard !names.isEmpty else { return nil }
        var seenLanguages: Set<String> = []
        for language in languages where seenLanguages.insert(language).inserted {
            var read: Set<String> = []
            for name in names.prefix(3) {
                // "Akira (manga)" comes after "Akira Toriyama", the film and the disambiguation page: every result named
                // like the series is read, and only those.
                for candidate in try await search(name, language: language) where read.insert(candidate).inserted
                    && names.contains(where: { TitleMatcher.similarity(withoutQualifier(candidate), $0) >= 0.85 }) {
                    guard let summary = try await summary(of: candidate, language: language),
                          isAboutSeries(summary, authors: authors) else { continue }
                    return summary
                }
            }
        }
        return nil
    }

    /// Titles of the articles a search finds, best first.
    static func search(_ text: String, language: String) async throws -> [String] {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: text), URLQueryItem(name: "srlimit", value: "8"),
            URLQueryItem(name: "srnamespace", value: "0"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let json = (try? JSONSerialization.jsonObject(with: try await get(components.url!))) as? [String: Any],
              let results = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["title"] as? String }
    }

    /// An article's summary; nil for a disambiguation page or an article that isn't there.
    static func summary(of title: String, language: String) async throws -> Summary? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-.()'"))) ?? title
        guard let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return nil }
        return parseSummary(try await get(url), language: language)
    }

    static func parseSummary(_ data: Data, language: String) -> Summary? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["type"] as? String == "standard",
              let title = json["title"] as? String,
              let extract = (json["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !extract.isEmpty else { return nil }
        let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return Summary(title: title, description: json["description"] as? String, extract: extract, url: page.flatMap(URL.init(string:)),
                       language: language)
    }

    /// The article is a series' or a book's, in the words of its description or of its first sentence, and names
    /// one of the authors when they are known: an homonym (a film, a town, a person) is no synopsis.
    static func isAboutSeries(_ summary: Summary, authors: [String]) -> Bool {
        let firstSentence = summary.extract.split(separator: ".", maxSplits: 1).first.map(String.init) ?? summary.extract
        let words = " " + FileNameParser.normalized([summary.description ?? "", firstSentence].joined(separator: " ")) + " "
        let kinds = ["bande dessinee", "bandes dessinees", " bd ", "comic", "manga", "manhwa", "webtoon", "roman", "novel", "serie",
                     "series", "album", "saga", "graphic", "fumetto", "historieta", "livre", "book"]
        guard kinds.contains(where: { words.contains($0) }) else { return false }
        // Adaptations share the title: the anime, the film, the game.
        let description = " " + FileNameParser.normalized(summary.description ?? "") + " "
        let adaptations = [" film ", "televise", "television", " tv ", "anime", "animation", "animated", "jeu video", "video game"]
        guard !adaptations.contains(where: { description.contains($0) }) else { return false }
        guard !authors.isEmpty else { return true }
        let text = FileNameParser.normalized(summary.extract)
        return authors.contains { author in
            guard let surname = FileNameParser.normalized(author).split(separator: " ").last, surname.count > 2 else { return false }
            return text.contains(surname)
        }
    }

    /// "Astérix (bande dessinée)" → "Astérix".
    static func withoutQualifier(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? title : stripped
    }

    private static func get(_ url: URL) async throws -> Data {
        await pacer.wait()
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Wikimedia asks for a User-Agent that says who calls and where to find them.
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return Data() }
        guard status < 400 else { throw BookCatalogError.http(service: "Wikipedia", status: status) }
        return data
    }
}
