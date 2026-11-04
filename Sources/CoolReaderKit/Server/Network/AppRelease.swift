import Foundation

/// A release of the Mac app on GitHub, as the app's updater reads it: its version and its zip.
public nonisolated struct AppRelease: Sendable, Equatable {
    public var version: String
    public var download: URL
    public var page: URL?

    /// The latest release's version ("v0.2.0" → "0.2.0") and its Mac zip, the universal one first; nil for a draft,
    /// a pre-release, or a release without a Mac zip.
    public static func parse(_ data: Data) -> AppRelease? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["draft"] as? Bool != true,
              json["prerelease"] as? Bool != true, let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let zips = assets.compactMap { asset -> (name: String, url: URL)? in
            guard let name = asset["name"] as? String, name.hasSuffix(".zip"), name.contains("-mac-"),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
            return (name, url)
        }
        guard let zip = zips.first(where: { $0.name.contains("universal") }) ?? zips.first(where: { $0.name.contains("arm64") }) ?? zips.first
        else { return nil }
        return AppRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, download: zip.url,
                          page: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// "0.10.0" is newer than "0.9.2", "0.2" than "0.1.9".
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
