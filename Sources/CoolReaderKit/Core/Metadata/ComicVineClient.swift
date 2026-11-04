import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Comic Vine, the encyclopedia of comics: series ("volumes" there), their synopsis, cover and the cover of each issue.
/// It needs a free key of one's own (comicvine.gamespot.com/api), which the admin gives on the Server page; without
/// one it is never asked. Its texts are in English. Comic Vine asks for one request a second at most and a User-Agent
/// of one's own. Only series titles are sent.
nonisolated enum ComicVineClient {
    nonisolated struct Volume: Sendable, Equatable {
        var id: Int
        var name: String
        var startYear: Int?
        var publisher: String?
        var issueCount: Int
        var summary: String?
        var coverURL: URL?
        var pageURL: URL?
    }

    private static let pacer = RequestPacer(interval: .seconds(1.1))

    static var key: String? { MetadataLocale.comicVineKey.flatMap { $0.isEmpty ? nil : $0 } }

    static func searchVolumes(_ query: String) async throws -> [Volume] {
        guard let key else { return [] }
        var components = URLComponents(string: "https://comicvine.gamespot.com/api/search/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "resources", value: "volume"), URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "field_list", value: "id,name,start_year,publisher,count_of_issues,image,deck,description,site_detail_url"),
        ]
        return parseVolumes(try await get(components.url!))
    }

    /// The covers of a series' issues, by number.
    static func issueCovers(volumeID: Int) async throws -> [Double: URL] {
        guard let key else { return [:] }
        var components = URLComponents(string: "https://comicvine.gamespot.com/api/issues/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "filter", value: "volume:\(volumeID)"), URLQueryItem(name: "field_list", value: "issue_number,image"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return parseIssueCovers(try await get(components.url!))
    }

    static func parseVolumes(_ data: Data) -> [Volume] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            // The deck is a line; the description, an article whose first paragraph tells what the series is.
            let description = (item["description"] as? String).map(EPUBText.plainText(fromHTML:))?
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count > 40 }
            let deck = (item["deck"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Volume(id: id, name: name, startYear: (item["start_year"] as? String).flatMap { Int($0) } ?? item["start_year"] as? Int,
                          publisher: (item["publisher"] as? [String: Any])?["name"] as? String,
                          issueCount: item["count_of_issues"] as? Int ?? 0,
                          summary: description ?? (deck?.isEmpty == false ? deck : nil),
                          coverURL: image(item["image"]), pageURL: (item["site_detail_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func parseIssueCovers(_ data: Data) -> [Double: URL] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }
        var covers: [Double: URL] = [:]
        for issue in results {
            guard let number = (issue["issue_number"] as? String).flatMap(Double.init), let url = image(issue["image"]) else { continue }
            if covers[number] == nil { covers[number] = url }
        }
        return covers
    }

    /// The series a folder is: the one named most like it, then the one with enough issues for the files, then the oldest
    /// (the original series rather than a later relaunch of the same name).
    static func best(_ volumes: [Volume], for title: String, highestNumber: Double?) -> Volume? {
        let scored = volumes.map { ($0, TitleMatcher.similarity($0.name, title)) }.filter { $0.1 >= 0.9 }
        return scored.max { a, b in
            if abs(a.1 - b.1) > 0.001 { return a.1 < b.1 }
            let aFits = highestNumber.map { Double(a.0.issueCount) >= $0 } ?? true
            let bFits = highestNumber.map { Double(b.0.issueCount) >= $0 } ?? true
            if aFits != bFits { return !aFits }
            return (a.0.startYear ?? 9999) > (b.0.startYear ?? 9999)
        }?.0
    }

    /// "…/scale_large/123.jpg": the large one, a cover that fits a poster.
    private static func image(_ value: Any?) -> URL? {
        guard let image = value as? [String: Any] else { return nil }
        return ["super_url", "original_url", "medium_url"].lazy.compactMap { image[$0] as? String }.compactMap(URL.init(string:)).first
    }

    private static func get(_ url: URL) async throws -> Data {
        await pacer.wait()
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw BookCatalogError.http(service: "Comic Vine", status: status) }
        return data
    }
}
