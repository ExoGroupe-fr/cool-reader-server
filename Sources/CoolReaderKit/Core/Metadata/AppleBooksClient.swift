import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

nonisolated enum BookCatalogError: LocalizedError {
    case http(service: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .http(let service, let status): "\(service) answered with an error (\(status))."
        }
    }
}

/// Apple Books' catalogue through the iTunes Search API: no key, the editions sold in the user's country with
/// their cover (any size), synopsis and genres in the store's language. Apple offers the API to map a library
/// to its catalogue and asks for about 20 requests a minute. Only titles and authors are sent.
nonisolated enum AppleBooksClient {
    private static let pacer = RequestPacer(interval: .seconds(3.1))

    /// The store country the server is set to: French editions for "fr".
    static var country: String { MetadataLocale.country }

    static func search(_ term: String, limit: Int = 25) async throws -> [BookMatch] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return parse(try await get(components.url!))
    }

    static func lookup(id: String) async throws -> BookMatch? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: country)]
        return parse(try await get(components.url!)).first
    }

    static func parse(_ data: Data) -> [BookMatch] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (json["results"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["kind"] as? String == "ebook", let id = item["trackId"] as? Int,
                  let title = item["trackName"] as? String else { return nil }
            let summary = (item["description"] as? String).map(EPUBText.plainText(fromHTML:))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let genres = (item["genres"] as? [String] ?? []).filter { !["Livres", "Books"].contains($0) }
            return BookMatch(source: .appleBooks, id: "ab:\(id)", title: title, subtitle: nil,
                             authors: authors(item["artistName"] as? String),
                             year: (item["releaseDate"] as? String).flatMap { Int($0.prefix(4)) },
                             releaseDate: item["releaseDate"] as? String,
                             language: language(of: [title, summary ?? ""].joined(separator: ". ")),
                             summary: summary?.isEmpty == false ? summary : nil,
                             genres: Array(genres.prefix(3)),
                             coverURL: (item["artworkUrl100"] as? String).flatMap(largeArtwork))
        }
    }

    /// "Jean Dupont, Marie Martin & Paul Durand" → three names.
    static func authors(_ artist: String?) -> [String] {
        guard let artist else { return [] }
        return artist.components(separatedBy: " & ")
            .flatMap { $0.components(separatedBy: ", ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Store artwork comes in any size: ".../100x100bb.jpg" → ".../600x600bb.jpg" (a bounding box, so the
    /// cover keeps its shape).
    static func largeArtwork(_ url: String) -> URL? {
        URL(string: url.replacingOccurrences(of: #"/\d+x\d+bb\.(jpg|png)$"#, with: "/600x600bb.jpg", options: .regularExpression))
    }

    /// The store doesn't say which language an edition is in: guess it from the title and the synopsis.
    private static func language(of text: String) -> String? {
        #if canImport(NaturalLanguage)
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
        #else
        nil
        #endif
    }

    private static func get(_ url: URL) async throws -> Data {
        await pacer.wait()
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw BookCatalogError.http(service: "Apple Books", status: status) }
        return data
    }
}
