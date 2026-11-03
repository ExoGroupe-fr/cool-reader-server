import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A manga entry from AniList (posters, banners, genres, staff).
nonisolated struct AniListMedia: Decodable, Sendable, Identifiable, Hashable {
    struct Title: Decodable, Sendable, Hashable {
        let romaji: String?
        let english: String?
        let native: String?
    }

    struct CoverImage: Decodable, Sendable, Hashable {
        let extraLarge: String?
        let large: String?
        let color: String?
    }

    struct FuzzyDate: Decodable, Sendable, Hashable {
        let year: Int?
    }

    struct StaffConnection: Decodable, Sendable, Hashable {
        let edges: [StaffEdge]
    }

    struct StaffEdge: Decodable, Sendable, Hashable {
        let role: String?
        let node: StaffNode
    }

    struct StaffNode: Decodable, Sendable, Hashable {
        let name: StaffName
    }

    struct StaffName: Decodable, Sendable, Hashable {
        let full: String?
    }

    let id: Int
    let title: Title
    let synonyms: [String]?
    let description: String?
    let coverImage: CoverImage?
    let bannerImage: String?
    let genres: [String]?
    let averageScore: Int?
    let popularity: Int?
    let startDate: FuzzyDate?
    let status: String?
    let volumes: Int?
    let chapters: Int?
    let format: String?
    let countryOfOrigin: String?
    let staff: StaffConnection?

    /// Every known title, most useful first.
    var allTitles: [String] {
        [title.english, title.romaji, title.native].compactMap { $0 } + (synonyms ?? [])
    }

    var coverURL: URL? { (coverImage?.extraLarge ?? coverImage?.large).flatMap(URL.init(string:)) }
    var bannerURL: URL? { bannerImage.flatMap(URL.init(string:)) }

    var authors: [String] {
        var names: [String] = []
        for edge in staff?.edges ?? [] {
            let role = edge.role?.lowercased() ?? ""
            guard role.contains("story") || role.contains("art") || role.contains("original") else { continue }
            guard let full = edge.node.name.full else { continue }
            let name = countryOfOrigin == "JP" ? Self.westernRomanization(full) : full
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Publishers drop long vowels: "Eiichirou Oda" → "Eiichiro Oda", "Kouhei" → "Kohei", "Yuusuke" → "Yusuke".
    static func westernRomanization(_ name: String) -> String {
        var result = name
        result = result.replacingOccurrences(of: "ou(?=[^aeiou]|\\b|$)", with: "o", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "uu", with: "u", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "Oo", with: "O")
        result = result.replacingOccurrences(of: "oo", with: "o")
        return result
    }

    var cleanDescription: String? {
        guard let description else { return nil }
        let text = EPUBText.plainText(fromHTML: description)
            .replacingOccurrences(of: #"\(Source:[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[Written by[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var localizedStatus: String? { MetadataTranslations.status(status) }
    var localizedGenres: [String] { (genres ?? []).compactMap(MetadataTranslations.genre) }

    /// The language of the original, from the country of origin: "ja" for Japan, "ko", "zh"…
    var originalLanguage: String? {
        switch countryOfOrigin {
        case "JP": "ja"
        case "KR": "ko"
        case "CN", "TW", "HK": "zh"
        case let country?: country.lowercased()
        case nil: nil
        }
    }

    var formatLabel: String {
        switch format {
        case "MANGA": countryOfOrigin == "KR" ? "Manhwa" : (countryOfOrigin == "CN" ? "Manhua" : "Manga")
        case "ONE_SHOT": "One shot"
        case "NOVEL": "Light novel"
        default: format?.capitalized ?? "Manga"
        }
    }
}

nonisolated enum AniListError: LocalizedError {
    case http(Int)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .http(let code): "AniList answered with an error (\(code))."
        case .rateLimited: "Too many requests to AniList, try again in a minute."
        }
    }
}

/// AniList's public GraphQL API (no account needed). Only series titles are sent.
nonisolated enum AniListClient {
    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private static let fields = """
        id title { romaji english native } synonyms description(asHtml: false)
        coverImage { extraLarge large color } bannerImage genres averageScore popularity
        startDate { year } status volumes chapters format countryOfOrigin
        staff(perPage: 6, sort: [RELEVANCE, ID]) { edges { role node { name { full } } } }
        """

    static func search(_ query: String, limit: Int = 8) async throws -> [AniListMedia] {
        let graphQL = """
            query ($search: String, $perPage: Int) {
              Page(perPage: $perPage) { media(search: $search, type: MANGA, sort: SEARCH_MATCH, isAdult: false) { \(fields) } }
            }
            """
        struct Response: Decodable {
            struct DataBody: Decodable {
                struct PageBody: Decodable { let media: [AniListMedia] }
                let Page: PageBody
            }
            let data: DataBody
        }
        let response: Response = try await post(graphQL, variables: ["search": query, "perPage": limit])
        return response.data.Page.media
    }

    static func media(id: Int) async throws -> AniListMedia {
        let graphQL = "query ($id: Int) { Media(id: $id, type: MANGA) { \(fields) } }"
        struct Response: Decodable {
            struct DataBody: Decodable { let Media: AniListMedia }
            let data: DataBody
        }
        let response: Response = try await post(graphQL, variables: ["id": id])
        return response.data.Media
    }

    private static func post<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 429 { throw AniListError.rateLimited }
        guard status < 400 else { throw AniListError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// AniList and MangaDex genres and statuses, kept in English and as codes: the reader that shows them
/// translates them, so every member sees them in their own language.
nonisolated enum MetadataTranslations {
    static func genre(_ genre: String) -> String? {
        genre == "Hentai" ? nil : genre
    }

    /// A series' publication status: finished, ongoing, upcoming, cancelled or hiatus.
    static func status(_ status: String?) -> String? {
        switch status?.uppercased() {
        case "FINISHED", "COMPLETED": "finished"
        case "RELEASING", "ONGOING": "ongoing"
        case "NOT_YET_RELEASED": "upcoming"
        case "CANCELLED": "cancelled"
        case "HIATUS": "hiatus"
        default: nil
        }
    }

    static var mangaDexLanguages: [String] { MetadataLocale.mangaDexLanguages }
}
