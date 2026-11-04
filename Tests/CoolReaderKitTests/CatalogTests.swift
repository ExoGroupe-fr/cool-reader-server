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

    /// « Watchmen/WATCHMEN - Les Gardiens - Intégrale.cbr » found nothing: a book alone is now looked up without its
    /// edition's words, then by its folder's name.
    @Test func aBookAloneIsLookedUpByItsTitleThenByItsFolder() {
        let book = SeriesMatchInput.Book(key: "1", fileName: "WATCHMEN - Les Gardiens - Intégrale.cbr", number: nil, format: .cbr)
        let series = SeriesMatchInput(folderTitle: "Watchmen", folderPath: "Watchmen", kind: .book, books: [book])
        let query = SeriesMatcher.bookQuery(for: series)
        #expect(query.title == "WATCHMEN - Les Gardiens")
        #expect(SeriesMatcher.folderQuery(for: series, besides: query).map(\.title) == ["Watchmen"])
        // A loose file has no folder of its own, and a folder named like its book adds nothing.
        let loose = SeriesMatchInput(folderTitle: "WATCHMEN - Les Gardiens", folderPath: nil, kind: .book, books: [book])
        #expect(SeriesMatcher.folderQuery(for: loose, besides: query).isEmpty)
        let named = SeriesMatchInput(folderTitle: "Watchmen", folderPath: "Watchmen", kind: .book,
                                     books: [.init(key: "1", fileName: "Watchmen (Alan Moore).cbr", number: nil, format: .cbr)])
        let namedQuery = SeriesMatcher.bookQuery(for: named)
        #expect(namedQuery.title == "Watchmen" && namedQuery.author == "Alan Moore")
        #expect(SeriesMatcher.folderQuery(for: named, besides: namedQuery).isEmpty)
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

    /// Albums named "Astérix 01 Astérix le gaulois" on disk and "Astérix - Astérix le Gaulois - n°1" in Apple Books.
    @Test func volumesWithTitlesOfTheirOwnAreFoundByTheirNumber() {
        let pool = [Self.edition(631320051, "Astérix - Astérix le Gaulois - n°1", authors: ["René Goscinny", "Albert Uderzo"]),
                    Self.edition(631319902, "Astérix - La Serpe d'or - n°2", authors: ["René Goscinny", "Albert Uderzo"]),
                    Self.edition(705085083, "Astérix - Le ciel lui tombe sur la tête - n°33", authors: ["René Goscinny", "Albert Uderzo"])]
        let series = BookQuery(title: "Astérix")
        let files = [("1", "Astérix 01 Astérix le gaulois.cbz", 1.0), ("2", "Astérix 02 La serpe d'or.cbz", 2.0),
                     ("33", "Astérix 33 Le ciel lui tombe sur la tête.cbz", 33.0), ("40", "Astérix 40 L'iris blanc.cbz", 40.0)]
        let volumes = files.map { key, name, number in
            (key: key, query: SeriesMatcher.volumeQuery(for: SeriesMatchInput.Book(key: key, fileName: name, number: number, format: .cbz),
                                                        series: series))
        }
        let found = BookMatcher.volumes(volumes, in: pool, series: series, language: "fr")
        #expect(found["1"]?.id == "ab:631320051")
        #expect(found["2"]?.id == "ab:631319902")
        #expect(found["33"]?.id == "ab:705085083")
        #expect(found["40"] == nil)
    }

    /// Apple Books' synopses carry numeric entities: "Le Papyrus de César,&#xa0;signé Didier Conrad".
    @Test func storeTextsLoseTheirEntities() {
        #expect(EPUBText.plainText(fromHTML: "César,&#xa0;signé&#160;Conrad : l&#39;album &eacute;tait «&#x2009;culte&#x2009;»")
                == "César, signé Conrad : l'album était « culte »")
        #expect(EPUBText.plainText(fromHTML: "Pepper&amp;Carrot &amp;lt;b&amp;gt; &unknown; &") == "Pepper&Carrot &lt;b&gt; &unknown; &")
    }

    @Test func readsWikipediaSummaries() throws {
        let json = #"""
            {"type": "standard", "title": "Astérix", "description": "série française de bandes dessinées",
             "extract": "Astérix est une série de bande dessinée française créée par René Goscinny et Albert Uderzo.",
             "content_urls": {"desktop": {"page": "https://fr.wikipedia.org/wiki/Ast%C3%A9rix"}}}
            """#
        let summary = try #require(WikipediaClient.parseSummary(Data(json.utf8), language: "fr"))
        #expect(summary.title == "Astérix" && summary.url?.absoluteString == "https://fr.wikipedia.org/wiki/Ast%C3%A9rix")
        #expect(WikipediaClient.isAboutSeries(summary, authors: ["René Goscinny", "Albert Uderzo"]))
        #expect(WikipediaClient.isAboutSeries(summary, authors: []))
        // Someone else's series of the same name.
        #expect(!WikipediaClient.isAboutSeries(summary, authors: ["Hergé"]))
        #expect(WikipediaClient.parseSummary(Data(#"{"type": "disambiguation", "title": "Akira", "extract": "Akira peut désigner…"}"#.utf8),
                                             language: "fr") == nil)
        #expect(WikipediaClient.withoutQualifier("Akira (manga)") == "Akira")
    }

    @Test func wikipediaPagesOfAdaptationsAreNoSynopsis() {
        func page(_ description: String, _ extract: String) -> WikipediaClient.Summary {
            WikipediaClient.Summary(title: "Akira", description: description, extract: extract, url: nil, language: "fr")
        }
        #expect(WikipediaClient.isAboutSeries(page("manga de Katsuhiro Otomo", "Akira est un manga de Katsuhiro Otomo."),
                                              authors: ["Katsuhiro Otomo"]))
        #expect(!WikipediaClient.isAboutSeries(page("film d'animation japonais de 1988", "Akira est un film d'animation de Katsuhiro Otomo."),
                                               authors: ["Katsuhiro Otomo"]))
        #expect(!WikipediaClient.isAboutSeries(page("commune française", "Akira est une commune."), authors: []))
    }

    @Test func readsComicVine() throws {
        let search = #"""
            {"error": "OK", "results": [
             {"id": 133286, "name": "Watchmen", "start_year": "2019", "count_of_issues": 1, "publisher": {"name": "DC Comics"},
              "deck": "A relaunch.", "image": {"super_url": "https://comicvine.example/2019.jpg"}},
             {"id": 3696, "name": "Watchmen", "start_year": "1986", "count_of_issues": 12, "publisher": {"name": "DC Comics"},
              "description": "<p>Short.</p><p>Watchmen is a twelve-issue limited series by Alan Moore and Dave Gibbons.</p>",
              "image": {"super_url": "https://comicvine.example/1986.jpg"}, "site_detail_url": "https://comicvine.example/watchmen/"},
             {"id": 9, "name": "Before Watchmen: Ozymandias", "start_year": "2012", "count_of_issues": 6}]}
            """#
        let volumes = ComicVineClient.parseVolumes(Data(search.utf8))
        #expect(volumes.count == 3)
        // The original series, which has the twelve issues the folder holds, rather than the relaunch.
        let best = try #require(ComicVineClient.best(volumes, for: "Watchmen", highestNumber: 12))
        #expect(best.id == 3696 && best.startYear == 1986 && best.publisher == "DC Comics")
        #expect(best.summary == "Watchmen is a twelve-issue limited series by Alan Moore and Dave Gibbons.")
        #expect(best.coverURL?.absoluteString == "https://comicvine.example/1986.jpg")
        let issues = #"{"results": [{"issue_number": "1", "image": {"super_url": "https://comicvine.example/1.jpg"}}, {"issue_number": "2", "image": {}}]}"#
        #expect(ComicVineClient.parseIssueCovers(Data(issues.utf8)) == [1: URL(string: "https://comicvine.example/1.jpg")!])
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
