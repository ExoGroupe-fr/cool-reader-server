import Foundation

/// The site's icons, drawn inline: the pages load nothing from elsewhere. Lines in the text's colour, 24 points square.
nonisolated enum Icon {
    private static func line(_ paths: String) -> String {
        "<svg class=\"icon\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">\(paths)</svg>"
    }

    static let home = line(#"<path d="M3.5 10.5 12 3.5l8.5 7"/><path d="M5.5 9v10.5a1 1 0 0 0 1 1H10v-6h4v6h3.5a1 1 0 0 0 1-1V9"/>"#)
    static let search = line(#"<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>"#)
    /// Manga: a book open in the middle.
    static let manga = line(#"<path d="M12 6.5C10 5 7 4.6 3.5 5v13c3.5-.4 6.5 0 8.5 1.5 2-1.5 5-1.9 8.5-1.5V5C17 4.6 14 5 12 6.5z"/><path d="M12 6.5v13"/>"#)
    /// BD and comics: a speech bubble.
    static let comics = line(#"<path d="M4.5 4.5h15a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H10l-4.5 3.5v-3.5h-1a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1z"/><path d="M8 9h8M8 12.5h5"/>"#)
    /// Novels and other books: a bound book.
    static let novel = line(#"<path d="M5.5 4.5h11a2.5 2.5 0 0 1 2.5 2.5v13h-11a2.5 2.5 0 0 1-2.5-2.5z"/><path d="M5.5 17.5A2.5 2.5 0 0 1 8 15h11"/>"#)
    /// Any other library: books on a shelf.
    static let books = line(#"<path d="M4.5 4.5h4v15h-4zM10.5 4.5h4v15h-4z"/><path d="m16.3 5.4 3.6-.9 3.1 14.4-3.6.9z"/>"#)
    static let folder = line(#"<path d="M3.5 7.5a2 2 0 0 1 2-2h3.8l2 2h7.2a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/>"#)
    static let members = line(#"<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19c.7-3 2.9-4.8 5.5-4.8s4.8 1.8 5.5 4.8"/><circle cx="16.8" cy="9.3" r="2.4"/><path d="M16.4 14.3c2.2.2 3.7 1.7 4.1 4.2"/>"#)
    static let devices = line(#"<rect x="7" y="3.5" width="10" height="17" rx="2.2"/><path d="M11 17.5h2"/>"#)
    static let server = line(#"<rect x="4" y="4.5" width="16" height="6.5" rx="1.8"/><rect x="4" y="13" width="16" height="6.5" rx="1.8"/><path d="M8 7.8h.01M8 16.3h.01"/>"#)
    static let signOut = line(#"<path d="M14 4.5h3.5a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H14"/><path d="M10 15.5 6.5 12 10 8.5M6.5 12h9"/>"#)
    static let play = #"<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l10.5-6.5z" fill="currentColor"/></svg>"#

    /// The brand's mark: an open book on the accent, coloured by the style sheet.
    static let mark = """
        <svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><rect class="mark-tile" width="32" height="32" rx="8"/>\
        <path class="mark-book" d="M16 10.4c-2.4-1.6-5.4-2-8.6-1.6v12.6c3.2-.4 6.2 0 8.6 1.6 2.4-1.6 5.4-2 8.6-1.6V8.8c-3.2-.4-6.2 0-8.6 1.6zM16 10.4v12.6"/></svg>
        """

    /// A library's icon, by what its name says it holds: "Mangas", "BD", "Comics", "Romans"…
    static func library(named name: String) -> String {
        let words = FileNameParser.normalized(name).split(separator: " ").map(String.init)
        if words.contains(where: { $0.hasPrefix("manga") || $0 == "manhwa" || $0 == "webtoons" }) { return manga }
        if words.contains(where: { ["bd", "bds", "comic", "comics", "bande", "bandes", "dessinee", "dessinees"].contains($0) }) { return comics }
        if words.contains(where: { ["roman", "romans", "livre", "livres", "book", "books", "ebook", "ebooks", "novel", "novels",
                                    "lecture", "lectures", "essais"].contains($0) }) { return novel }
        return books
    }
}
