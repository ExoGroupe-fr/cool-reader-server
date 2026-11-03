import Foundation

/// What one file of a series is: a volume ("Tome"), a chapter, an issue, or a standalone book.
nonisolated enum UnitKind: String, Codable, Sendable, CaseIterable {
    case volume
    case chapter
    case issue
    case book

}

nonisolated struct ParsedFileName: Sendable, Equatable {
    var seriesName: String?
    var number: Double?
    var kind: UnitKind?
    var extraTitle: String?
    /// The series the file names itself, as in "Rowling J. K - Harry Potter [Tome 3] - Le Prisonnier": a
    /// stronger hint than the folder it sits in ("Français").
    var namedSeries: String?
}

/// Understands the usual ways people name scans: "DRAGON BALL 12", "ONE PIECE TOME 101",
/// "Naruto Vol.72 (2015) [Digital]", "Berserk T03", "Solo Leveling - Chapitre 12", "0  Prologue".
nonisolated enum FileNameParser {
    private static let volumePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s._\-(\[])(?:tome|tomes|t|vol(?:ume)?|v|livre|book)\.?\s*(\d+(?:[.,]\d+)?)"#)
    private static let chapterPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s._\-(\[])(?:chapitre|chapter|chap|ch|c|ep(?:isode)?|scan)\.?\s*(\d+(?:[.,]\d+)?)"#)
    private static let issuePattern = try! NSRegularExpression(pattern: #"#\s*(\d+(?:[.,]\d+)?)"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
    /// "[Tome 3]", "(Vol. 2)": a volume marker in brackets, which is part of the name rather than a tag.
    private static let bracketedMarker = #"(?i)[\[(]\s*((?:tome|t|vol(?:ume)?|livre|book|chapitre|chapter|ch)\.?\s*\d+(?:[.,]\d+)?)\s*[\])]"#
    private static let separators = CharacterSet(charactersIn: " -–—_.:,;~").union(.whitespaces)

    /// `hasExtension: false` for folder names, where a dot isn't an extension ("Vol. 2").
    static func parse(_ fileName: String, seriesHint: String? = nil, hasExtension: Bool = true) -> ParsedFileName {
        var base = hasExtension ? (fileName as NSString).deletingPathExtension : fileName
        // "l_école", "qu_il": an apostrophe that a file system or a download turned into "_".
        base = base.replacingOccurrences(of: #"(?i)\b([cdjlmnst]|qu)_(?=[aeiouyhàâäéèêëîïôöûüù])"#, with: "$1’", options: .regularExpression)
        base = base.replacingOccurrences(of: "_", with: " ")
        let markedInBrackets = base.range(of: bracketedMarker, options: .regularExpression) != nil
        base = base.replacingOccurrences(of: bracketedMarker, with: " $1 ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}|\([^)]*\)"#, with: " ", options: .regularExpression)
        base = collapseSpaces(base)

        var remainder = base
        var seriesFromHint: String?
        if let hint = seriesHint, let range = prefixRange(of: hint, in: base) {
            seriesFromHint = hint
            remainder = collapseSpaces(String(base[range.upperBound...]).trimmingCharacters(in: separators))
        }

        var result = ParsedFileName()
        let candidates: [(NSRegularExpression, UnitKind?)] = [
            (volumePattern, .volume), (chapterPattern, .chapter), (issuePattern, .issue),
        ]
        var match: (range: Range<String.Index>, numberRange: Range<String.Index>)?
        for (regex, kind) in candidates {
            if let found = lastMatch(regex, in: remainder, group: 1) {
                match = found
                result.kind = kind
                break
            }
        }
        if match == nil {
            // A bare number: prefer the last one that does not look like a year.
            let all = allMatches(numberPattern, in: remainder)
            let nonYear = all.last { r in
                let text = remainder[r]
                return !(text.count == 4 && (text.hasPrefix("19") || text.hasPrefix("20")))
            }
            if let r = nonYear ?? (all.count == 1 ? all.first : nil) { match = (r, r) }
        }

        if let match {
            result.number = Double(remainder[match.numberRange].replacingOccurrences(of: ",", with: "."))
            let before = remainder[..<match.range.lowerBound].trimmingCharacters(in: separators)
            let after = remainder[match.numberRange.upperBound...].trimmingCharacters(in: separators)
            if let seriesFromHint {
                result.seriesName = seriesFromHint
                if !before.isEmpty, !isMarkerWord(before) { result.extraTitle = collapseSpaces(before) }
            } else if !before.isEmpty {
                result.seriesName = collapseSpaces(before)
            }
            if !after.isEmpty, !isMarkerWord(after) {
                result.extraTitle = [result.extraTitle, collapseSpaces(after)].compactMap { $0 }.joined(separator: " ")
            }
            // "Author - Series [Tome 3] - Title": the series is the part just before the marker.
            if markedInBrackets, result.kind == .volume || result.kind == .chapter,
               let series = before.components(separatedBy: " - ").last?.trimmingCharacters(in: separators), !series.isEmpty {
                result.namedSeries = collapseSpaces(series)
                if seriesFromHint == nil { result.seriesName = result.namedSeries }
            }
        } else {
            result.seriesName = seriesFromHint
            if seriesFromHint == nil || !remainder.isEmpty {
                result.extraTitle = remainder.isEmpty ? nil : remainder
            }
        }
        return result
    }

    /// "DRAGON BALL" → "Dragon Ball"; names that are not all caps are kept as typed.
    static func displayTitle(fromFolderName name: String) -> String {
        let cleaned = collapseSpaces(name.replacingOccurrences(of: "_", with: " "))
        let letters = cleaned.filter(\.isLetter)
        guard letters.count >= 3, letters == letters.uppercased(), letters != letters.lowercased() else { return cleaned }
        let small: Set<String> = ["de", "du", "des", "la", "le", "les", "et", "of", "the", "a", "an", "no", "to",
                                  "in", "on", "and", "or", "à", "au", "aux", "en", "d", "l"]
        let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        return words.enumerated().map { index, word in
            let raw = String(word)
            if raw.range(of: #"^(?=[MDCLXVI]+$)M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"#, options: .regularExpression) != nil,
               raw.count > 1 || raw == "I" {
                return raw
            }
            let lower = raw.lowercased()
            if index > 0, small.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    /// Lowercased, without accents or punctuation: used to compare titles.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "fr"))
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return collapseSpaces(String(mapped))
    }

    static func formatNumber(_ number: Double) -> String {
        if number.rounded() == number { return String(Int(number)) }
        return String(format: "%g", number).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Helpers

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isMarkerWord(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: separators)
        return ["tome", "t", "vol", "volume", "v", "chapitre", "chapter", "ch", "fr", "vf", "vostfr", "en", "fin", "end"].contains(lowered)
    }

    private static func prefixRange(of hint: String, in text: String) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        if let range = text.range(of: hint, options: options) { return range }
        // "SOLO LEVELLING" vs "Solo_Levelling-": compare without punctuation, then map back by length.
        let normalizedHint = normalized(hint)
        guard !normalizedHint.isEmpty else { return nil }
        var index = text.startIndex
        var consumed = ""
        while index < text.endIndex {
            consumed.append(text[index])
            index = text.index(after: index)
            if normalized(consumed) == normalizedHint { return text.startIndex..<index }
            if normalized(consumed).count > normalizedHint.count { break }
        }
        return nil
    }

    private static func lastMatch(_ regex: NSRegularExpression, in text: String, group: Int)
        -> (range: Range<String.Index>, numberRange: Range<String.Index>)? {
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: nsRange).last,
              let full = Range(match.range, in: text),
              let number = Range(match.range(at: group), in: text) else { return nil }
        return (full, number)
    }

    private static func allMatches(_ regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
