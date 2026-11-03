import Foundation

/// Information found in a `.nfo` file next to a series (scene-style text release notes, or Kodi XML).
nonisolated struct NFOInfo: Sendable, Equatable, Codable {
    var title: String?
    var summary: String?
    var authors: [String] = []
    var genres: [String] = []
    var year: Int?
    var status: String?
}

nonisolated enum NFOParser {
    static func parse(_ data: Data) -> NFOInfo? {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return parseXML(data)
        }
        return parseText(text)
    }

    // MARK: - Text release notes

    static func parseText(_ text: String) -> NFOInfo? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var info = NFOInfo()

        // Sections are framed by lines of dashes or stars, with the section name in between.
        var sections: [(title: String, body: [String])] = []
        var index = 0
        var currentTitle = ""
        var currentBody: [String] = []
        func isRule(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 8 && trimmed.allSatisfy { "-*=_~#".contains($0) }
        }
        while index < lines.count {
            let line = lines[index]
            if isRule(line), index + 2 < lines.count, isRule(lines[index + 2]) {
                sections.append((currentTitle, currentBody))
                currentTitle = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                currentBody = []
                index += 3
                continue
            }
            currentBody.append(line)
            index += 1
        }
        sections.append((currentTitle, currentBody))

        let summaryNames = ["general information", "synopsis", "résumé", "resume", "description", "histoire", "plot", "summary"]
        if let section = sections.first(where: { section in
            let title = section.title.lowercased()
            return summaryNames.contains { title.contains($0) }
        }) {
            let paragraphs = section.body
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .split(separator: "", omittingEmptySubsequences: true)
                .map { $0.joined(separator: " ") }
            let summary = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { info.summary = summary }
        }

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 40, !value.isEmpty else { continue }
            switch key {
            case "titre", "title", "nom":
                info.title = info.title ?? value
            case "auteur", "auteurs", "author", "authors", "scénariste", "scenariste", "writer",
                 "dessinateur", "illustrateur", "artist", "mangaka":
                for name in splitList(value) where !info.authors.contains(name) { info.authors.append(name) }
            case "genre", "genres", "genre littéraire", "genre litteraire":
                info.genres = splitList(value)
            case "date de parution", "année", "annee", "year", "date", "parution":
                if let match = value.range(of: #"(19|20)\d{2}"#, options: .regularExpression) {
                    info.year = Int(value[match])
                }
            case "statut", "status", "chapitre final", "état", "etat":
                let lowered = value.lowercased()
                if lowered.contains("cours") || lowered.contains("ongoing") { info.status = "En cours" }
                else if lowered.contains("termin") || lowered.contains("fini") || lowered.contains("complete") { info.status = "Terminé" }
            default:
                break
            }
        }
        return info == NFOInfo() ? nil : info
    }

    // MARK: - Kodi-style XML

    private static func parseXML(_ data: Data) -> NFOInfo? {
        guard let root = MiniXML.parse(data) else { return nil }
        var info = NFOInfo()
        func value(_ name: String) -> String? {
            let text = root.child(name)?.trimmedText ?? ""
            return text.isEmpty ? nil : text
        }
        info.title = value("title")
        info.summary = value("plot") ?? value("outline") ?? value("summary") ?? value("description")
        info.genres = root.children("genre").map(\.trimmedText).filter { !$0.isEmpty }
        info.authors = (root.children("author") + root.children("credits") + root.children("writer"))
            .map(\.trimmedText).filter { !$0.isEmpty }
        if let year = value("year") ?? value("premiered") { info.year = Int(year.prefix(4)) }
        info.status = value("status")
        return info == NFOInfo() ? nil : info
    }

    private static func splitList(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "/,;&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
