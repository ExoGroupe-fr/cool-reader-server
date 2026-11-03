import Foundation

/// The language and store country the catalogues are asked in: the editions, synopses and covers follow
/// them. The app takes them from the device; the server from its settings, once at startup.
nonisolated enum MetadataLocale {
    nonisolated(unsafe) static var language = "en"
    nonisolated(unsafe) static var country = "us"

    /// MangaDex's language keys, most specific first: "pt-br" before "pt".
    static var mangaDexLanguages: [String] {
        switch language.lowercased() {
        case "pt-br": ["pt-br", "pt"]
        case "zh-hant": ["zh-hk", "zh"]
        case "zh-hans": ["zh"]
        case "es": ["es", "es-la"]
        case let other: [String(other.prefix(while: { $0 != "-" }))]
        }
    }
}
