import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MangaDex's public API: French synopses, per-volume covers (so volumes still in iCloud get their real
/// cover without downloading hundreds of megabytes), and European titles AniList doesn't list.
nonisolated enum MangaDexClient {
    nonisolated struct Manga: Sendable, Identifiable, Hashable {
        let id: String
        let mainTitle: String
        let titles: [String]
        let descriptions: [String: String]
        let aniListID: Int?
        let coverFileName: String?
        let year: Int?
        let status: String?
        let genres: [String]
        let authors: [String]
        let originalLanguage: String?

        var coverURL: URL? {
            coverFileName.flatMap { URL(string: "https://uploads.mangadex.org/covers/\(id)/\($0).512.jpg") }
        }

        /// The synopsis in the app's language, else English, else French.
        var bestDescription: String? {
            localizedDescription ?? [descriptions["en"], descriptions["fr"]].lazy.compactMap { $0 }
                .map(MangaDexClient.cleanDescription).first { !$0.isEmpty }
        }

        /// The synopsis in the app's language only: AniList already gives one in English.
        var localizedDescription: String? {
            MetadataTranslations.mangaDexLanguages.lazy.compactMap { descriptions[$0] }
                .map(MangaDexClient.cleanDescription).first { !$0.isEmpty }
        }

        var localizedStatus: String? { MetadataTranslations.status(status) }

        /// Fan-made recolourings and doujinshi share the title of the real series.
        var isFanEdition: Bool {
            let lowered = mainTitle.lowercased()
            return lowered.contains("fan colored") || lowered.contains("doujinshi") || lowered.contains("(official colored)")
        }
    }

    nonisolated struct VolumeCover: Sendable {
        let volume: Double
        let locale: String
        let url: URL
    }

    private static let base = URL(string: "https://api.mangadex.org")!

    static func search(_ title: String) async throws -> [Manga] {
        var components = URLComponents(url: base.appendingPathComponent("manga"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "order[relevance]", value: "desc"),
            URLQueryItem(name: "contentRating[]", value: "safe"),
            URLQueryItem(name: "contentRating[]", value: "suggestive"),
            URLQueryItem(name: "includes[]", value: "cover_art"),
            URLQueryItem(name: "includes[]", value: "author"),
            URLQueryItem(name: "includes[]", value: "artist"),
        ]
        let json = try await get(components.url!)
        let items = json["data"] as? [[String: Any]] ?? []
        return items.compactMap(parseManga)
    }

    private static func parseManga(_ item: [String: Any]) -> Manga? {
        guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { return nil }
        let titleMap = attributes["title"] as? [String: String] ?? [:]
        var titles = Array(titleMap.values)
        for alt in attributes["altTitles"] as? [[String: String]] ?? [] { titles.append(contentsOf: alt.values) }
        let links = attributes["links"] as? [String: String] ?? [:]
        let genres = (attributes["tags"] as? [[String: Any]] ?? []).compactMap { tag -> String? in
            guard let tagAttributes = tag["attributes"] as? [String: Any], tagAttributes["group"] as? String == "genre",
                  let name = (tagAttributes["name"] as? [String: String])?["en"] else { return nil }
            return MetadataTranslations.genre(name)
        }
        var coverFileName: String?
        var authors: [String] = []
        for relation in item["relationships"] as? [[String: Any]] ?? [] {
            let type = relation["type"] as? String
            let relationAttributes = relation["attributes"] as? [String: Any]
            if type == "cover_art" { coverFileName = relationAttributes?["fileName"] as? String }
            if type == "author" || type == "artist", let name = relationAttributes?["name"] as? String, !authors.contains(name) {
                authors.append(name)
            }
        }
        let language = attributes["originalLanguage"] as? String
        if let language, !["ja", "ko", "zh", "zh-hk"].contains(language) {
            authors = authors.map { name in
                let words = name.split(separator: " ")
                return words.count == 2 ? "\(words[1]) \(words[0])" : name
            }
        }
        return Manga(id: id, mainTitle: titleMap["en"] ?? titleMap.values.first ?? "", titles: titles,
                     descriptions: attributes["description"] as? [String: String] ?? [:],
                     aniListID: links["al"].flatMap(Int.init), coverFileName: coverFileName,
                     year: attributes["year"] as? Int, status: attributes["status"] as? String, genres: genres,
                     authors: authors, originalLanguage: attributes["originalLanguage"] as? String)
    }

    static func volumeCovers(mangaID: String) async throws -> [VolumeCover] {
        var covers: [VolumeCover] = []
        var offset = 0
        while true {
            var components = URLComponents(url: base.appendingPathComponent("cover"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "manga[]", value: mangaID),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "order[volume]", value: "asc"),
            ]
            let json = try await get(components.url!)
            let items = json["data"] as? [[String: Any]] ?? []
            for item in items {
                guard let attributes = item["attributes"] as? [String: Any],
                      let fileName = attributes["fileName"] as? String,
                      let volumeText = attributes["volume"] as? String,
                      let volume = Double(volumeText),
                      let url = URL(string: "https://uploads.mangadex.org/covers/\(mangaID)/\(fileName).512.jpg") else { continue }
                covers.append(VolumeCover(volume: volume, locale: attributes["locale"] as? String ?? "", url: url))
            }
            let total = json["total"] as? Int ?? 0
            offset += 100
            if items.isEmpty || offset >= total || offset >= 500 { break }
        }
        return covers
    }

    /// One cover per volume: the edition in the app's language first, then Japanese, then anything.
    static func preferredCovers(_ covers: [VolumeCover]) -> [Double: URL] {
        var rank = ["ja": 1, "ko": 1, "en": 2]
        for language in MetadataTranslations.mangaDexLanguages { rank[language] = 0 }
        var best: [Double: (Int, URL)] = [:]
        for cover in covers {
            let score = rank[cover.locale] ?? 3
            if let current = best[cover.volume], current.0 <= score { continue }
            best[cover.volume] = (score, cover.url)
        }
        return best.mapValues(\.1)
    }

    static func cleanDescription(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\r", with: "")
        cleaned = cleaned.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?m)^-{3,}[\s\S]*$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for (plain, ligature) in [("voeu", "vœu"), ("coeur", "cœur"), ("soeur", "sœur"), ("oeil", "œil"),
                                  ("oeuvre", "œuvre"), ("noeud", "nœud"), ("boeuf", "bœuf"), ("oeuf", "œuf")] {
            cleaned = cleaned.replacingOccurrences(of: "\\b\(plain)", with: ligature, options: .regularExpression)
            let capitalized = plain.prefix(1).uppercased() + plain.dropFirst()
            let capitalLigature = ligature.prefix(1).uppercased() + ligature.dropFirst()
            cleaned = cleaned.replacingOccurrences(of: "\\b\(capitalized)", with: capitalLigature, options: .regularExpression)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw AniListError.http(status) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Fuzzy title comparison used to match a folder name with an online entry.
nonisolated enum TitleMatcher {
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(FileNameParser.normalized(a).replacingOccurrences(of: " ", with: ""))
        let y = Array(FileNameParser.normalized(b).replacingOccurrences(of: " ", with: ""))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Best score of `query` against any of `titles`, with the title that scored it.
    static func best(_ query: String, among titles: [String]) -> (score: Double, title: String?) {
        var best: (Double, String?) = (0, nil)
        for title in titles {
            let score = similarity(query, title)
            if score > best.0 { best = (score, title) }
        }
        return best
    }

    /// British and French spellings that search engines miss ("Levelling" → "Leveling"): doubled letters
    /// collapsed. nil when nothing changes.
    static func spellingVariant(_ query: String) -> String? {
        var result = ""
        var previous: Character?
        for character in query {
            if let previous, character.isLetter, character.lowercased() == previous.lowercased(), "lnrst".contains(character.lowercased()) {
                continue
            }
            result.append(character)
            previous = character
        }
        return result == query ? nil : result
    }

    /// Ranks an AniList entry for a local series: title first, then the real series over its novels,
    /// spin-offs and webcomics (format, a plausible number of volumes, popularity).
    static func rank(_ media: AniListMedia, query: String, localCount: Int, kind: UnitKind) -> Double? {
        let score = best(query, among: media.allTitles).score
        guard score >= 0.86 else { return nil }
        var rank = score
        if media.format == "MANGA" { rank += 0.04 }
        let published = kind == .chapter ? media.chapters : media.volumes
        if let published, localCount > 3, Double(published) < Double(localCount) * 0.6 { rank -= 0.15 }
        rank += min(0.06, log10(Double(media.popularity ?? 0) + 1) * 0.012)
        return rank
    }
}
