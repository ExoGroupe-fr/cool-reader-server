import Foundation

/// A book from an online catalogue (Apple Books, Open Library): a row of « Associer… » and what a series
/// of novels, essays or BD takes from it.
nonisolated struct BookMatch: Sendable, Identifiable, Hashable {
    enum Source: String, Sendable {
        case appleBooks
        case openLibrary
    }

    let source: Source
    /// "ab:<track id>" or "ol:<work key>", stored in `Series.catalogID`.
    let id: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let year: Int?
    /// "2020-08-20T07:00:00Z" when the store gives it: of the editions sold under one title, the first one out opens
    /// the series.
    let releaseDate: String?
    /// "fr", "en"… when known.
    let language: String?
    let summary: String?
    let genres: [String]
    let coverURL: URL?

    var sourceName: String {
        switch source {
        case .appleBooks: "Apple Books"
        case .openLibrary: "Open Library"
        }
    }

    /// The title without edition notes: "Germinal (édition 2022)" → "Germinal".
    var displayTitle: String { BookMatcher.withoutNotes(title) }

    /// Titles to compare with a file name: the title, and the title with its subtitle.
    var matchTitles: [String] {
        guard let subtitle, !subtitle.isEmpty else { return [title] }
        return [title, "\(title) : \(subtitle)"]
    }

    /// Volume number written in the title: "Les Aventures de Tom - Tome 2 - Le Lac" → 2.
    var number: Double? { BookQuery.volumeNumber(in: title) }

    /// The series part of a volume's title: "Les Misérables - Tome 1 : Fantine" → "Les Misérables".
    var seriesName: String? { BookQuery.seriesName(in: title) }
}

/// What to search a book by: its title cleaned of the noise of file names, its author, its volume number.
nonisolated struct BookQuery: Equatable, Sendable {
    var title: String
    var author: String?
    /// "Tome 3", "T03", "n°12", "Vol. 2", or a final roman numeral ("… II").
    var number: Double?
    /// The number comes from a marker ("Tome 3"), not from a final numeral that may belong to the title.
    var hasVolumeMarker = false

    /// The title to search: without a final numeral, which catalogues write "(Tome 2)" or "Vol. 2" if at all.
    var searchTitle: String {
        guard number != nil, !hasVolumeMarker else { return title }
        let stripped = title.replacingOccurrences(of: #"\s+(?:I{1,3}|IV|V|VI{0,3}|IX|X)$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? title : stripped
    }

    /// Title and author, for full-text searches.
    var searchText: String { [searchTitle, author].compactMap { $0 }.joined(separator: " ") }

    /// Reads the usual ways books are named:
    /// "Les Misérables - Victor Hugo", "Madame Bovary (Gustave Flaubert) [Retail]",
    /// "Le.Comte.de.Monte-Cristo.1844.Alexandre.Dumas", "Verne Jules - Voyages extraordinaires [Tome 2] - Vingt
    /// mille lieues sous les mers", "Les Trois Mousquetaires II", "appel de la forêt, L' - Jack London".
    static func parse(_ name: String) -> BookQuery {
        // File names on disk are often decomposed ("e" + accent): compose them for the patterns below.
        var text = name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "_", with: " ")
        var author: String?
        var number: Double?
        var hasMarker = false

        // Scene names: dots instead of spaces, the year between the title and the author.
        if !text.contains(" "), text.filter({ $0 == "." }).count >= 2 {
            text = text.replacingOccurrences(of: ".", with: " ")
            if let year = text.range(of: #"\s(1[5-9]\d{2}|20\d{2})(\s|$)"#, options: .regularExpression) {
                let after = String(text[year.upperBound...]).trimmingCharacters(in: .whitespaces)
                if looksLikeName(after) { author = after }
                text = String(text[..<year.lowerBound])
            }
        }

        // Bracketed notes: a volume marker, the author of Calibre's "Title (Author)", or tags to drop.
        for group in topLevelGroups(in: text).reversed() {
            let inner = removingGroups(String(text[group].dropFirst().dropLast())).trimmingCharacters(in: .whitespaces)
            if let found = markerNumber(inner) {
                number = number ?? found
                hasMarker = true
            } else if author == nil, !isTag(inner), looksLikeName(inner) || isHandle(inner) {
                author = inner
            }
            text.replaceSubrange(group, with: " ")
        }

        // "Title - Author", "Author - Series - Title", "Series - Tome 3 - Title".
        var parts = text.components(separatedBy: " - ")
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "–—")) }
            .flatMap { splitLooseDash($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts.removeAll { part in
            guard let found = markerNumber(part) else { return false }
            number = number ?? found
            hasMarker = true
            return true
        }
        if author == nil, parts.count >= 2 {
            if looksLikeName(parts[parts.count - 1]) {
                author = parts.removeLast()
            } else if looksLikeName(parts[0]) {
                author = parts.removeFirst()
            }
        }
        var title = parts.joined(separator: " - ")

        // Calibre's sort order puts the article last: "appel de la forêt, L'" → "L'appel de la forêt".
        if let article = title.range(of: #",\s*(L'|L’|Le|La|Les|The|A|An|Un|Une)\s*$"#, options: .regularExpression) {
            let word = title[article].dropFirst().trimmingCharacters(in: .whitespaces)
            let rest = title[..<article.lowerBound].trimmingCharacters(in: .whitespaces)
            title = word.hasSuffix("'") || word.hasSuffix("’") ? word + rest : "\(word) \(rest)"
        }
        // "Arsène Lupin T03", or a final roman numeral kept in the title: "Les Trois Mousquetaires II".
        if let marker = title.range(of: #"(?i)\s(?:tome|t|vol\.?|volume|n°|livre)\.?\s*\d+\s*$"#, options: .regularExpression) {
            number = number ?? markerNumber(String(title[marker]))
            hasMarker = true
            title = String(title[..<marker.lowerBound])
        } else if number == nil, let numeral = title.range(of: #"\s(I{1,3}|IV|V|VI{0,3}|IX|X)$"#, options: .regularExpression),
                  title[..<numeral.lowerBound].split(separator: " ").count >= 2 {
            number = romanValue(title[numeral].trimmingCharacters(in: .whitespaces))
        }
        title = title.replacingOccurrences(of: #",(?=\p{L})"#, with: ", ", options: .regularExpression)
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -,.:"))
        return BookQuery(title: title.isEmpty ? name : title, author: author, number: number, hasVolumeMarker: hasMarker)
    }

    /// Volume number of a catalogue title: "Tome 2", "T2", "n°12", "Vol. 2", "(Tome II)", "#3".
    static func volumeNumber(in title: String) -> Double? {
        guard let match = firstMarker(in: title) else { return nil }
        return number(fromMarker: match.value)
    }

    /// "Les Misérables - Tome 1 : Fantine" → "Les Misérables"; "Astérix - Le Tour de Gaule - n°5" → "Astérix".
    static func seriesName(in title: String) -> String? {
        guard let match = firstMarker(in: title) else { return nil }
        let head = title[..<match.range.lowerBound]
        let first = head.components(separatedBy: " - ").first ?? String(head)
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,(").union(.whitespaces))
        return name.isEmpty ? nil : name
    }

    // MARK: - Helpers

    private static let markerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:tome|volume|vol\.?|livre|book|partie|part)\s*|n°\s*|#)(\d+(?:[.,]\d+)?|[IVX]+)\b|\bt\.?\s?(\d+)\b"#)

    private static func firstMarker(in text: String) -> (range: Range<String.Index>, value: String)? {
        guard let result = markerPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        for group in 1...2 {
            if let value = Range(result.range(at: group), in: text) { return (range, String(text[value])) }
        }
        return nil
    }

    private static func number(fromMarker value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: ".")) ?? romanValue(value.uppercased())
    }

    /// The number of a part that is only a marker: "Tome 3", "T03", "n°12", "Vol. 2", "#4", "Tome II".
    private static func markerNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = firstMarker(in: trimmed), match.range == trimmed.startIndex..<trimmed.endIndex else { return nil }
        return number(fromMarker: match.value)
    }

    /// "La Structure des étoiles- Jean Dupont": a dash with a space on one side only still separates.
    private static func splitLooseDash(_ text: String) -> [String] {
        text.components(separatedBy: "- ").flatMap { $0.components(separatedBy: " -") }
    }

    private static func romanValue(_ text: String) -> Double? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total > 0 && total <= 20 ? Double(total) : nil
    }

    /// Release tags, formats and sources: no part of a title or a name.
    private static func isTag(_ text: String) -> Bool {
        let lowered = FileNameParser.normalized(text)
        if lowered.range(of: #"^(1[5-9]\d{2}|20\d{2})$"#, options: .regularExpression) != nil { return true }
        let tags = ["z library", "retail", "digital", "completed", "complete", "epub", "ebook", "pdf", "fr", "french",
                    "francais", "vf", "vo", "eng", "english", "hq", "ocr", "scan", "calibre", "converted", "illustre",
                    "illustrated", "integrale", "edition", "unabridged", "poche"]
        return tags.contains { lowered == $0 || lowered.hasPrefix($0 + " ") || lowered.hasSuffix(" " + $0) }
    }

    /// A web pen name in brackets: "(plume2024)". Plain single words are left out: they are often publishers.
    private static func isHandle(_ text: String) -> Bool {
        !text.contains(" ") && text.contains(where: \.isLetter) && text.contains(where: \.isNumber) && text.count <= 24
    }

    /// "Victor Hugo", "Hugo V.", "Jean-Paul Sartre", "Ursula K. Le Guin", "Jean d'Ormesson".
    static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        guard 2...6 ~= words.count, text.count <= 48 else { return false }
        let leading: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "the", "a", "an", "tome", "vol"]
        if let first = words.first?.lowercased(), leading.contains(first) || first.hasPrefix("l'") || first.hasPrefix("l’") {
            return false
        }
        let particles: Set<String> = ["de", "du", "des", "van", "von", "der", "di", "da", "del", "le", "la", "y"]
        var letters = 0
        for word in words {
            let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            letters += core.filter(\.isLetter).count
            let lowered = core.lowercased()
            if particles.contains(lowered) { continue }
            if lowered.hasPrefix("d'") || lowered.hasPrefix("d’") {
                // "d'Ormesson" is a particle before a name; "d'envol" ("Potion d'envol") is a title's.
                guard core.dropFirst(2).first?.isUppercase == true else { return false }
                continue
            }
            if core.count <= 3, core.allSatisfy({ $0.isUppercase || $0 == "." }) { continue }  // initials: "J.", "J.K"
            guard let initial = core.first, initial.isUppercase, !core.contains(where: \.isNumber) else { return false }
        }
        return letters >= 4
    }

    /// Ranges of the outermost "(…)" and "[…]" groups.
    private static func topLevelGroups(in text: String) -> [Range<String.Index>] {
        var groups: [Range<String.Index>] = []
        var depth = 0
        var start: String.Index?
        for index in text.indices {
            switch text[index] {
            case "(", "[":
                if depth == 0 { start = index }
                depth += 1
            case ")", "]":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start { groups.append(start..<text.index(after: index)) }
            default:
                break
            }
        }
        return groups
    }

    private static func removingGroups(_ text: String) -> String {
        var result = text
        for group in topLevelGroups(in: text).reversed() { result.replaceSubrange(group, with: "") }
        return result
    }
}

/// Ranks catalogue results against a book: title first (tolerant to articles, subtitles and edition notes),
/// then the author, the volume number, the language and the cover. Study guides and summaries sink.
nonisolated enum BookMatcher {
    struct Score: Equatable, Sendable {
        var rank: Double
        var title: Double
        /// The title only matched a part of the other ("Candide" in "Candide, ou l'optimisme").
        var partial: Bool
        /// nil when the author isn't known on one side.
        var authorMatches: Bool?
        var isStudyGuide: Bool
        var hasCover: Bool
        /// A single significant word ("Germinal"): too vague to trust without the author…
        var vague: Bool
        /// …unless it names a volume of a series exactly ("Astérix - Tome 1 - …" for the series « Astérix »).
        var namesSeriesVolume: Bool

        /// Good enough to apply without asking.
        var isStrong: Bool {
            guard !isStudyGuide, hasCover else { return false }
            if let authorMatches { return authorMatches && title >= 0.8 }
            guard !partial, title >= 0.92 else { return false }
            return !vague || (namesSeriesVolume && title >= 0.999)
        }
    }

    /// Small words that don't tell titles apart.
    private static let stopWords: Set<String> = ["le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "et", "a",
                                                 "au", "aux", "en", "the", "an", "of", "and", "to", "in", "on", "pour", "par", "sur"]

    /// `series`: the query names a series of several books, compared with the series part of volume titles.
    static func score(_ match: BookMatch, for query: BookQuery, language: String, series: Bool = false) -> Score {
        var title: (score: Double, partial: Bool)
        var namesSeriesVolume = false
        if series, let name = match.seriesName {
            title = (similarity(query.title, name), false)
            namesSeriesVolume = true
        } else {
            title = titleScore(query.title, match.matchTitles)
            // "Les Mémoires (Tome 2) - Le Retour" is volume 2 of « Les memoires II »: a whole match.
            if title.partial, let number = query.number, match.number == number, let name = match.seriesName {
                let whole = similarity(withoutNumeral(query.title), name)
                if whole >= title.score - 0.001 {
                    title = (whole, false)
                    namesSeriesVolume = true
                }
            }
        }
        var rank = title.partial ? min(title.score, 0.85) : title.score
        var authorMatches: Bool?
        if let author = query.author, !match.authors.isEmpty {
            let matches = Self.authorMatches(author, among: match.authors)
            authorMatches = matches
            rank += matches ? 0.15 : -0.25
        }
        let guide = isStudyGuide(match)
        if guide { rank -= 0.5 }
        if let number = query.number, let other = match.number {
            rank += other == number ? 0.1 : (query.hasVolumeMarker ? -0.3 : -0.05)
        }
        if match.language == language { rank += 0.04 }
        if match.coverURL != nil { rank += 0.03 }
        return Score(rank: rank, title: title.score, partial: title.partial, authorMatches: authorMatches,
                     isStudyGuide: guide, hasCover: match.coverURL != nil, vague: tokens(query.title).count < 2,
                     namesSeriesVolume: namesSeriesVolume)
    }

    /// Best results first.
    static func sorted(_ matches: [BookMatch], for query: BookQuery, language: String) -> [BookMatch] {
        matches.map { ($0, score($0, for: query, language: language).rank) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The best result, if it is good enough to apply without asking. For a series, a tie goes to the edition out
    /// first: a store may sell the parts of a series under one title ("Pepper&Carrot" three times, episodes 1 to
    /// 10, 11 to 20, 21 to 30), and its order says nothing of which comes first.
    static func best(_ matches: [BookMatch], for query: BookQuery, language: String, series: Bool = false) -> BookMatch? {
        let strong = matches.map { ($0, score($0, for: query, language: language, series: series)) }.filter { $0.1.isStrong }
        guard let top = strong.max(by: { $0.1.rank < $1.1.rank }) else { return nil }
        guard series else { return top.0 }
        let tied = strong.filter { $0.1.rank >= top.1.rank - 0.001 }.compactMap { match, _ in match.releaseDate.map { (match, $0) } }
        return tied.min { $0.1 < $1.1 }?.0 ?? top.0
    }

    /// A catalogue book found for volumes of different numbers or titles stands for none of them: an edition of the
    /// whole series that matched by its name ("Pepper&Carrot" for episodes 2 to 6). The same volume twice, a CBZ
    /// and a PDF, keeps it.
    static func withoutSharedBooks(_ found: [String: BookMatch], volumes: [(key: String, query: BookQuery)]) -> [String: BookMatch] {
        let identity = Dictionary(volumes.map { volume in
            (volume.key, "\(volume.query.number.map { "\($0)" } ?? "-") \(FileNameParser.normalized(volume.query.title))")
        }, uniquingKeysWith: { first, _ in first })
        var kept = found
        for keys in Dictionary(grouping: found.keys, by: { found[$0]!.id }).values where keys.count > 1 {
            if Set(keys.map { identity[$0] ?? $0 }).count > 1 {
                for key in keys { kept[key] = nil }
            }
        }
        return kept
    }

    /// The volumes of a series among catalogue results, by the caller's keys: each by its own title when its file
    /// name has one ("… [Tome 2] - Cosette"), else by its number ("Les Aventures de Tom T03" → "Les Aventures de
    /// Tom - Tome 3 - …"). A numbered volume whose own title isn't written as the catalogue writes it ("Astérix 01
    /// Astérix le gaulois" for "Astérix - Astérix le Gaulois - n°1") is then looked for by its number too.
    static func volumes(_ volumes: [(key: String, query: BookQuery)], in pool: [BookMatch], series: BookQuery,
                        language: String) -> [String: BookMatch] {
        var found: [String: BookMatch] = [:]
        for volume in volumes {
            if TitleMatcher.similarity(volume.query.title, series.title) < 0.9 || volume.query.number == nil {
                found[volume.key] = best(pool, for: volume.query, language: language)
            }
            if found[volume.key] == nil, let number = volume.query.number {
                var query = series
                query.number = number
                query.hasVolumeMarker = true
                found[volume.key] = best(pool.filter { $0.number == number }, for: query, language: language, series: true)
            }
        }
        return found
    }

    /// Edit distance or shared words, whichever is better; parts of titles count as partial matches.
    static func titleScore(_ query: String, _ titles: [String]) -> (score: Double, partial: Bool) {
        var best: (score: Double, partial: Bool) = (0, false)
        let queryParts = segments(query)
        for title in titles {
            for (cIndex, candidate) in segments(title).enumerated() {
                for (qIndex, part) in queryParts.enumerated() {
                    let score = similarity(part, candidate)
                    let partial = qIndex > 0 || cIndex > 0
                    // A whole-title match beats a partial one of the same score.
                    if score > best.score + 0.001 || (abs(score - best.score) <= 0.001 && best.partial && !partial) {
                        best = (score, partial)
                    }
                }
            }
        }
        return best
    }

    /// "Hugo Victor" and "V. Hugo" share a surname (the last word of either name); first names don't count.
    static func authorMatches(_ author: String, among authors: [String]) -> Bool {
        let wanted = nameWords(author)
        guard let wantedLast = wanted.last else { return false }
        for other in authors {
            let words = nameWords(other)
            guard let last = words.last else { continue }
            if Set(words).intersection(wanted).contains(where: { $0 == last || $0 == wantedLast }) { return true }
            // "Flaubert" and "Flaubret": a typo in a surname.
            if last.count >= 5, TitleMatcher.similarity(wantedLast, last) >= 0.8 { return true }
        }
        return false
    }

    /// Summaries, reading notes and study guides that borrow the title of the book.
    static func isStudyGuide(_ match: BookMatch) -> Bool {
        let title = FileNameParser.normalized(match.title)
        let markers = ["summary of", "resume de", "fiche de lecture", "analyse de l oeuvre", "analyse de l œuvre", "study guide",
                       "guide d etude", "sommaire et guide", "notes on", "cliffsnotes", "sparknotes", "explication de texte"]
        if markers.contains(where: { title.contains($0) }) { return true }
        let publishers: Set<String> = ["lepetitlitteraire", "supersummary", "encyclopaedia universalis", "pagecraft summaries", "easy reads"]
        return match.authors.contains { publishers.contains(FileNameParser.normalized($0)) }
    }

    /// Removes edition notes in brackets: "Germinal (Enhanced Edition)" → "Germinal".
    static func withoutNotes(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }

    // MARK: - Helpers

    /// "Les Trois Mousquetaires II" → "Les Trois Mousquetaires".
    private static func withoutNumeral(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s+(?:[IVX]+|\d+)$"#, with: "", options: .regularExpression)
    }

    /// The whole title, then its parts without volume markers: "Les Misérables - Tome 1 : Fantine" →
    /// ["Les Misérables - Tome 1 : Fantine", "Les Misérables", "Fantine"].
    private static func segments(_ title: String) -> [String] {
        let whole = withoutNotes(title)
        let parts = whole.components(separatedBy: " - ")
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ":,–—")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return [whole] }
        return [whole] + parts.filter { BookQuery.volumeNumber(in: $0) == nil }
    }

    private static func tokens(_ text: String) -> [String] {
        FileNameParser.normalized(text).split(separator: " ").map(String.init).filter { !stopWords.contains($0) }
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let distance = TitleMatcher.similarity(x.joined(separator: " "), y.joined(separator: " "))
        let shared = Double(Set(x).intersection(y).count)
        let overlap = 2 * shared / Double(Set(x).count + Set(y).count)
        return max(distance, overlap)
    }

    /// Lowercased name words without initials: "V. Hugo" → ["hugo"].
    private static func nameWords(_ name: String) -> [String] {
        FileNameParser.normalized(name).split(separator: " ").map(String.init).filter { $0.count > 2 }
    }
}

/// Spaces out the requests to one service: Apple asks for about 20 a minute.
actor RequestPacer {
    private let interval: Duration
    private var next: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Waits for this caller's turn. The slot is taken before sleeping, so concurrent callers queue up.
    func wait() async {
        let now = ContinuousClock.now
        let slot = max(now, next ?? now)
        next = slot.advanced(by: interval)
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}
