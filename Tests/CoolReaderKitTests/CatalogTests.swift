import Foundation
import Testing
@testable import CoolReaderKit

/// How catalogue results are read and ranked, without the network: names in file names, editions sold under one
/// title, and a book found for several volumes.
struct CatalogTests {
    private static func edition(_ id: Int, _ title: String, released: String? = nil,
                                authors: [String] = ["David Revoy", "Antonio Parisi"]) -> BookMatch {
        BookMatch(source: .appleBooks, id: "ab:\(id)", title: title, subtitle: nil, authors: authors,
                  year: released.flatMap { Int($0.prefix(4)) }, releaseDate: released, language: "en", summary: nil,
                  genres: [], coverURL: URL(string: "https://example.com/\(id).jpg"))
    }

    @Test func tellsTitlesFromNames() {
        #expect(!BookQuery.looksLikeName("Potion d'envol"))
        #expect(BookQuery.looksLikeName("Jean d'Ormesson"))
        #expect(BookQuery.looksLikeName("Valéry Giscard d’Estaing"))
        #expect(BookQuery.parse("Pepper&Carrot - Episode 01 - Potion d'envol").author == nil)
        #expect(BookQuery.parse("La Gloire de mon père - Marcel Pagnol").author == "Marcel Pagnol")
    }

    /// Apple Books in France sells the episodes in three parts, all titled "Pepper&Carrot", in this order.
    @Test func aSeriesTakesTheFirstEditionOfATitle() {
        let pool = [Self.edition(1531297659, "Pepper&Carrot", released: "2020-09-10T07:00:00Z"),
                    Self.edition(1528570749, "Pepper&Carrot", released: "2020-08-20T07:00:00Z"),
                    Self.edition(1539328412, "Pepper&Carrot", released: "2020-11-08T08:00:00Z")]
        let query = BookQuery(title: "Pepper&Carrot", author: "David Revoy", number: 1)
        #expect(BookMatcher.best(pool, for: query, language: "fr", series: true)?.id == "ab:1528570749")
        // A single book keeps the store's order.
        #expect(BookMatcher.best(pool, for: query, language: "fr")?.id == "ab:1531297659")
    }

    @Test func aBookFoundForSeveralVolumesIsNoneOfTheirs() {
        let whole = Self.edition(1, "Pepper&Carrot")
        let fifth = Self.edition(5, "Blacksad - Tome 5", authors: ["Juan Díaz Canales"])
        let sixth = Self.edition(6, "Blacksad - Tome 6", authors: ["Juan Díaz Canales"])
        let volumes: [(key: String, query: BookQuery)] = [
            ("2", BookQuery(title: "Pepper&Carrot - Episode 02 - Les potions arc-en-ciel", number: 2, hasVolumeMarker: true)),
            ("3", BookQuery(title: "Pepper&Carrot - Episode 03 - L'ingrédient secret", number: 3, hasVolumeMarker: true)),
            ("5.cbz", BookQuery(title: "Blacksad", number: 5, hasVolumeMarker: true)),
            ("5.pdf", BookQuery(title: "Blacksad", number: 5, hasVolumeMarker: true)),
            ("6", BookQuery(title: "Blacksad", number: 6, hasVolumeMarker: true)),
        ]
        let found = ["2": whole, "3": whole, "5.cbz": fifth, "5.pdf": fifth, "6": sixth]
        let kept = BookMatcher.withoutSharedBooks(found, volumes: volumes)
        #expect(kept["2"] == nil && kept["3"] == nil)
        // The same volume twice, in two formats, keeps its book.
        #expect(kept["5.cbz"]?.id == "ab:5" && kept["5.pdf"]?.id == "ab:5")
        #expect(kept["6"]?.id == "ab:6")
    }
}
