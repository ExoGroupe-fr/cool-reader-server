import Foundation

/// Metadata found inside a file (ComicInfo.xml, EPUB package).
nonisolated struct EmbeddedMetadata: Sendable, Equatable, Codable {
    var title: String?
    var series: String?
    var number: Double?
    var summary: String?
    var writers: [String] = []
    var artists: [String] = []
    var genres: [String] = []
    var year: Int?
    var isRightToLeft: Bool?
    var language: String?
}

nonisolated enum BookOpenError: Error, Equatable {
    case unreadable
    case empty
}

/// ComicInfo.xml (ComicRack) metadata.
nonisolated enum ComicInfo {
    static func parse(_ data: Data) -> EmbeddedMetadata? {
        guard let root = MiniXML.parse(data), root.name.caseInsensitiveCompare("ComicInfo") == .orderedSame else { return nil }
        func value(_ name: String) -> String? {
            let text = root.child(name)?.trimmedText ?? ""
            return text.isEmpty ? nil : text
        }
        func list(_ name: String) -> [String] {
            (value(name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var metadata = EmbeddedMetadata()
        metadata.title = value("Title")
        metadata.series = value("Series")
        metadata.number = value("Number").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            ?? value("Volume").flatMap { Double($0) }
        metadata.summary = value("Summary")
        metadata.writers = list("Writer")
        metadata.artists = list("Penciller") + list("Inker").filter { !list("Penciller").contains($0) }
        metadata.genres = list("Genre")
        metadata.year = value("Year").flatMap { Int($0) }
        metadata.language = value("LanguageISO")
        if let manga = value("Manga")?.lowercased() {
            metadata.isRightToLeft = manga == "yesandrighttoleft" ? true : (manga == "no" ? false : nil)
        }
        return metadata
    }
}
