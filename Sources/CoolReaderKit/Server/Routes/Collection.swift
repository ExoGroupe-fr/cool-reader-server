import Foundation
import NIOHTTP1

/// The pages every member sees, in the spirit of Plex: what they're reading, what's new and each library's series
/// on the home page, a library's series, a series with its volumes, search, and a reader for comics and PDFs.
nonisolated enum CollectionRoutes {
    static func add(to router: inout Router, context: ServerContext) {
        router.add(.GET, "/reader.js") { _ in
            var response = Response(contentType: "text/javascript; charset=utf-8", data: Data(readerScript.utf8))
            response.headers.add(name: "Cache-Control", value: "public, max-age=3600")
            return response
        }

        router.add(.GET, "/") { request in
            if await context.setup.isNeeded { return .redirect("/setup") }
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let strings = Strings(request.language)
            let libraries = context.store.visibleLibraries(for: caller.user)
            var page = WebPage(title: context.serverName, strings: strings, caller: caller, libraries: libraries, section: "/")
            let finished = context.store.finishedCounts(userID: caller.user.id)
            if caller.user.isAdmin {
                let scanning = await context.scanner.isScanning
                let pending = context.store.pendingSeries(limit: 1000).count
                let status = [scanning ? strings["scanning"] : nil, pending > 0 && context.config.onlineMetadata ? strings["matching"] : nil]
                    .compactMap { $0 }
                if !status.isEmpty { page.add("<p class=\"status\">\(h(status.joined(separator: " · ")))</p>") }
            }
            if libraries.isEmpty {
                page.add("<p class=\"empty\">\(h(strings["noLibraries"]))</p>")
                if caller.user.isAdmin { page.add("<p><a class=\"button\" href=\"/libraries\">\(h(strings["addLibrary"]))</a></p>") }
            }
            let reading = context.store.readingNow(userID: caller.user.id, libraryIDs: libraries.map(\.id), limit: 20)
            let recent = context.store.recentSeries(libraryIDs: libraries.map(\.id), limit: 20)
            // The page opens on the series being read, else on a new one, with a banner if one of the newest has one.
            let hasBanner = { (series: SeriesRecord) in series.bannerPath != nil || series.match?.bannerURL != nil }
            let featured: (series: SeriesRecord, label: String)? =
                reading.lazy.compactMap { context.store.series(id: $0.book.seriesID) }.first.map { ($0, strings["continueReading"]) }
                ?? (recent.prefix(10).first(where: hasBanner) ?? recent.first).map { ($0, strings["justAdded"]) }
            if let featured {
                page.add(hero(featured.series, books: context.store.books(seriesID: featured.series.id),
                              progress: context.store.progress(userID: caller.user.id, seriesID: featured.series.id), strings: strings,
                              overline: featured.label))
            }
            let shelves = libraries.map { (library: $0, series: context.store.series(libraryID: $0.id)) }
            if !shelves.isEmpty { page.add(libraryTiles(shelves, strings: strings)) }
            let readingCards = reading.compactMap { item -> String? in
                guard let series = context.store.series(id: item.book.seriesID) else { return nil }
                return bookCard(item.book, series: series, progress: item.progress, strings: strings, showSeries: true)
            }
            if !readingCards.isEmpty { page.add(shelf(strings["continueReading"], cards: readingCards, strings: strings)) }
            let nextCards = context.store.upNext(userID: caller.user.id, libraryIDs: libraries.map(\.id), limit: 20).compactMap { book -> String? in
                guard let series = context.store.series(id: book.seriesID) else { return nil }
                return bookCard(book, series: series, progress: nil, strings: strings, showSeries: true)
            }
            if !nextCards.isEmpty { page.add(shelf(strings["upNext"], cards: nextCards, strings: strings)) }
            if libraries.count > 1, !recent.isEmpty {
                page.add(shelf(strings["recent"], cards: recent.map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) },
                               strings: strings))
            }
            for (library, series) in shelves {
                let cards = series.prefix(24).map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) }
                page.add(shelf(library.name, detail: strings.seriesCount(library.seriesCount), link: "/library/\(library.id)",
                               icon: Icon.library(named: library.name), cards: Array(cards), empty: strings["noSeries"], strings: strings))
            }
            page.add("<p class=\"hint\">\(h(strings["opdsHint"])) <code>\(h(AdminRoutes.host(request)))/opds</code> \(h(strings["opdsHint2"]))</p>")
            return .html(page.html)
        }

        router.add(.GET, "/library/:id") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let library = try context.visibleLibrary(request.parameter("id"), for: caller)
            let strings = Strings(request.language)
            let byDate = request.query["sort"] == "recent"
            var page = WebPage(title: library.name, strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), section: "/library/\(library.id)")
            var series = context.store.series(libraryID: library.id)
            // The newest covers, in a slanted row behind the library's name.
            let newest = series.sorted { $0.addedAt > $1.addedAt }.prefix(10).map(\.id)
            let mosaic = newest.isEmpty ? "" : "<div class=\"mosaic\" aria-hidden=\"true\">"
                + (0..<max(10, newest.count)).map { "<img src=\"/api/v1/series/\(newest[$0 % newest.count])/cover\" alt=\"\">" }.joined() + "</div>"
            let counts = [strings.seriesCount(library.seriesCount), strings.bookCount(library.bookCount, kind: .book)].joined(separator: " · ")
            page.add("""
                <section class="library-head">\(mosaic)<div class="library-title">\(Icon.library(named: library.name))\
                <div><h1>\(h(library.name))</h1><p class="facts">\(h(counts))</p></div></div>
                <p class="sort"><a href="/library/\(library.id)"\(byDate ? "" : " aria-current=\"true\"")>\(h(strings["sortTitle"]))</a>
                <a href="/library/\(library.id)?sort=recent"\(byDate ? " aria-current=\"true\"" : "")>\(h(strings["recent"]))</a></p></section>
                """)
            if byDate { series.sort { $0.addedAt > $1.addedAt } }
            let finished = context.store.finishedCounts(userID: caller.user.id)
            page.add(filterBar(series, library: library, request: request, strings: strings))
            series = filtered(series, request: request, finished: finished, started: context.store.startedSeries(userID: caller.user.id))
            page.add(series.isEmpty ? "<p class=\"empty\">\(h(strings["noSeries"]))</p>"
                                    : grid(series.map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) }))
            return .html(page.html)
        }

        router.add(.GET, "/search") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let strings = Strings(request.language)
            let text = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var page = WebPage(title: strings["search"], strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), search: text)
            page.add("<h1>\(h(text.isEmpty ? strings["search"] : strings.searchTitle(text)))</h1>")
            let results = context.store.searchSeries(text, libraryIDs: context.visibleLibraryIDs(for: caller)) { [$0, strings.genre($0)] }
            let finished = context.store.finishedCounts(userID: caller.user.id)
            if !text.isEmpty {
                page.add(results.isEmpty ? "<p class=\"empty\">\(h(strings["noResults"]))</p>"
                                         : grid(results.map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) }))
            }
            return .html(page.html)
        }

        router.add(.GET, "/series/:id") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            let strings = Strings(request.language)
            let books = context.store.books(seriesID: series.id)
            let progress = context.store.progress(userID: caller.user.id, seriesID: series.id)
            var page = WebPage(title: series.title, strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), section: "/library/\(series.libraryID)")
            page.add(hero(series, books: books, progress: progress, strings: strings))
            if caller.user.isAdmin {
                page.add("""
                    <p class="admin-tools"><a href="/series/\(series.id)/match">\(h(strings["fixMatch"]))</a>\
                    <a href="/series/\(series.id)/match#edit">\(h(strings["editSeries"]))</a></p>
                    """)
            }
            let cards = books.map { book in
                bookCard(book, series: series, progress: progress[book.id], strings: strings, showSeries: false, actions: true,
                         canDelete: caller.user.isAdmin && context.allowsDeletion)
            }
            let allRead = !books.isEmpty && books.allSatisfy { progress[$0.id]?.finished == true }
            page.add("""
                <div class="row-head"><h2>\(h(strings.bookCount(books.count, kind: series.kind)))</h2>\
                <form method="post" action="/series/\(series.id)/read"><input type="hidden" name="read" value="\(allRead ? "0" : "1")">\
                <button class="link">\(h(strings[allRead ? "markSeriesUnread" : "markSeriesRead"]))</button></form></div>
                """)
            page.add(grid(cards, wide: true))
            if books.contains(where: \.isText) { page.add("<p class=\"hint\">\(h(strings["textBooksHint"]))</p>") }
            return .html(page.html)
        }

        router.add(.GET, "/read/:id") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let (book, series, _) = try context.visibleBook(request.parameter("id"), for: caller)
            guard isReadableOnline(book), let count = book.pageCount, count > 0 else { return .redirect("/series/\(series.id)") }
            let strings = Strings(request.language)
            let saved = context.store.progress(userID: caller.user.id, bookID: book.id)
            let wanted = request.query["page"].flatMap(Int.init) ?? (saved?.finished == true ? 0 : saved?.page ?? 0)
            let readable = context.store.books(seriesID: series.id).filter(isReadableOnline)
            let next = readable.firstIndex { $0.id == book.id }.flatMap { $0 + 1 < readable.count ? readable[$0 + 1] : nil }
            return .html(readerPage(book: book, series: series, count: count, start: min(max(wanted, 0), count - 1), next: next,
                                    rightToLeft: isRightToLeft(book, series: series, library: context.store.library(id: book.libraryID)),
                                    strings: strings))
        }

        router.add(.POST, "/series/:id/read") { request in
            try AdminRoutes.checkOrigin(request)
            let caller = try await context.requireCaller(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try context.store.setSeriesRead(userID: caller.user.id, seriesID: series.id, read: request.form["read"] == "1")
            return .redirect("/series/\(series.id)")
        }

        // Marking a book read or unread writes progress the member's devices pick up, rather than deleting it.
        router.add(.POST, "/books/:id/read") { request in
            try AdminRoutes.checkOrigin(request)
            let caller = try await context.requireCaller(request)
            let (book, series, _) = try context.visibleBook(request.parameter("id"), for: caller)
            let read = request.form["read"] == "1"
            try context.store.setProgress(userID: caller.user.id, ProgressRecord(
                bookID: book.id, page: read ? max(0, (book.pageCount ?? 1) - 1) : 0, finished: read, position: nil,
                fraction: read ? 1 : 0, updatedAt: Date()))
            return .redirect("/series/\(series.id)#book-\(book.id)")
        }
    }

    // MARK: - Pieces

    /// A book the browser can read: pages of an image book, or a PDF whose pages the server can draw.
    static func isReadableOnline(_ book: BookRecord) -> Bool {
        guard !book.isText, book.analysisError == nil, let count = book.pageCount, count > 0 else { return false }
        return book.format == .pdf || !book.pagePaths.isEmpty
    }

    /// Manga turn right to left: as the book says (ComicInfo), else by the series' language of origin, else by
    /// a library or folder named for manga, as Cool Reader decides.
    static func isRightToLeft(_ book: BookRecord, series: SeriesRecord, library: LibraryRecord?) -> Bool {
        if let declared = book.metadata?.isRightToLeft { return declared }
        if let language = series.match?.originalLanguage?.lowercased() { return language == "ja" }
        return [library?.name, series.folderPath].compactMap { $0?.lowercased() }.contains { $0.contains("manga") }
    }

    /// How much of a book is read, 0 to 1.
    static func fraction(_ progress: ProgressRecord?, book: BookRecord) -> Double {
        guard let progress else { return 0 }
        if progress.finished { return 1 }
        if let fraction = progress.fraction { return min(max(fraction, 0), 1) }
        guard let count = book.pageCount, count > 1 else { return 0 }
        return min(Double(progress.page) / Double(count - 1), 1)
    }

    static func shelf(_ title: String, detail: String? = nil, link: String? = nil, icon: String = "", cards: [String], empty: String? = nil,
                      strings: Strings) -> String {
        let heading = link.map { "<a href=\"\($0)\">\(icon)\(h(title))</a>" } ?? icon + h(title)
        let more = link.map { "<a class=\"more\" href=\"\($0)\">\(h(strings["seeAll"])) ›</a>" } ?? ""
        let body = cards.isEmpty ? "<p class=\"empty\">\(h(empty ?? ""))</p>" : "<div class=\"shelf\">\(cards.joined())</div>"
        return "<section class=\"row-section\"><div class=\"row-head\"><h2>\(heading)\(detail.map { " <small>\(h($0))</small>" } ?? "")</h2>\(more)</div>\(body)</section>"
    }

    /// The libraries as tiles, each with its newest covers fanned out over their own colours.
    static func libraryTiles(_ shelves: [(library: LibraryRecord, series: [SeriesRecord])], strings: Strings) -> String {
        let tiles = shelves.map { shelf -> String in
            let icon = Icon.library(named: shelf.library.name)
            let covers = shelf.series.sorted { $0.addedAt > $1.addedAt }.prefix(3)
            let art = covers.isEmpty ? "<span class=\"tile-empty\">\(icon)</span>"
                : covers.map { "<img src=\"/api/v1/series/\($0.id)/cover\" alt=\"\" loading=\"lazy\">" }.joined()
            let backdrop = covers.first.map { "<span class=\"tile-backdrop\" style=\"background-image: url('/api/v1/series/\($0.id)/cover')\"></span>" } ?? ""
            let counts = [strings.seriesCount(shelf.library.seriesCount), strings.bookCount(shelf.library.bookCount, kind: .book)]
            return """
                <a class="tile" href="/library/\(shelf.library.id)">\(backdrop)<span class="tile-art">\(art)</span>\
                <span class="tile-text">\(icon)<strong>\(h(shelf.library.name))</strong><span class="sub">\(h(counts.joined(separator: " · ")))</span></span></a>
                """
        }
        return "<section class=\"row-section\"><div class=\"row-head\"><h2>\(h(strings["yourLibraries"]))</h2></div><div class=\"tiles\">\(tiles.joined())</div></section>"
    }

    /// A library's series by reading state (all, not begun, begun, read) and genre, as the page's address asks.
    static func filtered(_ series: [SeriesRecord], request: Request, finished: [Int: Int], started: Set<Int>) -> [SeriesRecord] {
        var series = series
        switch request.query["state"] {
        case "unread": series = series.filter { !started.contains($0.id) }
        case "reading": series = series.filter { started.contains($0.id) && (finished[$0.id] ?? 0) < $0.bookCount }
        case "read": series = series.filter { $0.bookCount > 0 && (finished[$0.id] ?? 0) >= $0.bookCount }
        default: break
        }
        if let genre = request.query["genre"], !genre.isEmpty { series = series.filter { $0.genres.contains(genre) } }
        return series
    }

    /// The reading states, then the library's most frequent genres, as links that keep the other choices.
    static func filterBar(_ series: [SeriesRecord], library: LibraryRecord, request: Request, strings: Strings) -> String {
        let state = request.query["state"] ?? ""
        let genre = request.query["genre"] ?? ""
        func link(state: String, genre: String, label: String, current: Bool) -> String {
            var query: [String] = []
            if let sort = request.query["sort"] { query.append("sort=\(sort)") }
            if !state.isEmpty { query.append("state=\(state)") }
            if !genre.isEmpty { query.append("genre=\(genre.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? genre)") }
            let href = "/library/\(library.id)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
            return "<a href=\"\(h(href))\"\(current ? " aria-current=\"true\"" : "")>\(h(label))</a>"
        }
        let states = [("", "filterAll"), ("unread", "filterUnread"), ("reading", "filterReading"), ("read", "filterFinished")]
            .map { link(state: $0.0, genre: genre, label: strings[$0.1], current: state == $0.0) }
        var counts: [String: Int] = [:]
        for item in series { for name in item.genres { counts[name, default: 0] += 1 } }
        let genres = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10).map(\.key)
        var html = "<div class=\"filters\"><p class=\"sort\">\(states.joined())</p>"
        if !genres.isEmpty {
            html += "<p class=\"sort genres\">" + link(state: state, genre: "", label: strings["allGenres"], current: genre.isEmpty)
                + genres.map { link(state: state, genre: $0, label: strings.genre($0), current: genre == $0) }.joined() + "</p>"
        }
        return html + "</div>"
    }

    static func grid(_ cards: [String], wide: Bool = false) -> String {
        "<div class=\"grid\(wide ? " volumes" : "")\">\(cards.joined())</div>"
    }

    /// A series' cover: unread volumes counted once some are read, a check once all are.
    static func seriesCard(_ series: SeriesRecord, finished: Int, strings: Strings) -> String {
        var badge = ""
        if series.bookCount > 0, finished >= series.bookCount {
            badge = "<span class=\"badge done\" title=\"\(h(strings["readBadge"]))\">✓</span>"
        } else if finished > 0 {
            badge = "<span class=\"badge\" title=\"\(h(strings.unreadCount(series.bookCount - finished)))\">\(series.bookCount - finished)</span>"
        }
        return """
            <a class="card" href="/series/\(series.id)"><span class="art"><img src="/api/v1/series/\(series.id)/cover" alt="" loading="lazy">\(badge)</span>\
            <strong>\(h(series.title))</strong><span class="sub">\(h(strings.bookCount(series.bookCount, kind: series.kind)))</span></a>
            """
    }

    /// A book's cover, with how much of it is read; on a series' page, its download and read marks too.
    static func bookCard(_ book: BookRecord, series: SeriesRecord, progress: ProgressRecord?, strings: Strings, showSeries: Bool,
                         actions: Bool = false, canDelete: Bool = false) -> String {
        let read = fraction(progress, book: book)
        let readable = isReadableOnline(book)
        let href = readable ? "/read/\(book.id)" : "/api/v1/books/\(book.id)/file"
        var state = ""
        if progress?.finished == true {
            state = "<span class=\"badge done\" title=\"\(h(strings["readBadge"]))\">✓</span>"
        } else if read > 0 {
            state = "<span class=\"bar\"><span style=\"width: \(Int((read * 100).rounded()))%\"></span></span>"
        }
        let name = strings.bookTitle(book, kind: series.kind)
        var sub: [String] = []
        if showSeries { sub.append(name) }
        if let progress, !progress.finished, let count = book.pageCount, count > 1, !book.isText {
            sub.append(strings.pageOf(min(progress.page + 1, count), count))
        } else if !showSeries {
            sub += [book.pageCount.map { "\($0) \(strings["pages"])" }, book.analysisError != nil ? strings["unreadable"] : nil].compactMap { $0 }
        }
        var tools = ""
        if actions {
            let finished = progress?.finished == true
            tools = """
                <span class="tools"><a href="/api/v1/books/\(book.id)/file" title="\(h(strings["download"])) · \(h(strings.size(book.fileSize)))">\(h(strings["download"]))</a>\
                <form method="post" action="/books/\(book.id)/read"><input type="hidden" name="read" value="\(finished ? "0" : "1")">\
                <button class="link">\(h(strings[finished ? "markUnread" : "markRead"]))</button></form>\
                \(canDelete ? "<a class=\"danger\" href=\"/books/\(book.id)/delete\">\(h(strings["deleteBook"]))</a>" : "")</span>
                """
        }
        return """
            <div class="card" id="book-\(book.id)"><a href="\(href)"><span class="art"><img src="/api/v1/books/\(book.id)/cover" alt="" loading="lazy">\(state)</span>\
            <strong>\(h(showSeries ? series.title : name))</strong><span class="sub">\(h(sub.joined(separator: " · ")))</span></a>\(tools)</div>
            """
    }

    /// The top of a series' page: its banner (or its poster, blurred), poster, facts and the button that reads on. With
    /// a line above the title, the home page opens on it, with a way to the series.
    static func hero(_ series: SeriesRecord, books: [BookRecord], progress: [Int: ProgressRecord], strings: Strings,
                     overline: String? = nil) -> String {
        let hasBanner = series.bannerPath != nil || series.match?.bannerURL != nil
        let backdrop = hasBanner ? "/api/v1/series/\(series.id)/banner" : "/api/v1/series/\(series.id)/cover"
        // No catalogue gives BD a banner: a series of several books shows its own covers instead, side by side.
        let covers = hasBanner || books.count < 3 ? [] : Array(books.prefix(18).map(\.id))
        let background = covers.isEmpty ? "<div class=\"backdrop\" style=\"background-image: url('\(backdrop)')\"></div>"
            : "<div class=\"mosaic\" aria-hidden=\"true\">"
                + (0..<max(18, covers.count)).map { "<img src=\"/api/v1/books/\(covers[$0 % covers.count])/cover\" alt=\"\">" }.joined()
                + "</div>"
        let facts = [series.authors.joined(separator: ", "), series.year.map(String.init), series.status.map { strings[$0] },
                     strings.bookCount(series.bookCount, kind: series.kind)].compactMap { $0 }.filter { !$0.isEmpty }
        let genres = series.genres.map { "<span class=\"chip\">\(h(strings.genre($0)))</span>" }.joined()
        let readable = books.filter(isReadableOnline)
        var action = ""
        if let next = readable.first(where: { progress[$0.id]?.finished != true }) {
            let started = (progress[next.id]?.page ?? 0) > 0
            let label = started ? strings["resume"] : strings["read"]
            let name = readable.count > 1 ? " · \(strings.bookTitle(next, kind: series.kind))" : ""
            action = "<a class=\"button play\" href=\"/read/\(next.id)\">\(Icon.play)\(h(label + name))</a>"
        } else if let first = readable.first {
            action = "<a class=\"button play\" href=\"/read/\(first.id)?page=0\">\(Icon.play)\(h(strings["readAgain"]))</a>"
        }
        let spotlight = overline != nil
        if spotlight { action += "<a class=\"button glass\" href=\"/series/\(series.id)\">\(h(strings["seeSeries"]))</a>" }
        let title = spotlight ? "<a href=\"/series/\(series.id)\">\(h(series.title))</a>" : h(series.title)
        return """
            <section class="hero\(hasBanner ? " banner" : "")\(covers.isEmpty ? "" : " covers")\(spotlight ? " spotlight" : "")">\(background)
            <div class="hero-body"><img class="poster" src="/api/v1/series/\(series.id)/cover" alt="">
            <div class="info">\(overline.map { "<p class=\"overline\">\(h($0))</p>" } ?? "")<h1>\(title)</h1><p class="facts">\(h(facts.joined(separator: " · ")))</p>
            \(genres.isEmpty ? "" : "<p class=\"chips\">\(genres)</p>")\(action.isEmpty ? "" : "<p class=\"actions\">\(action)</p>")
            \(series.summary.map { "<p class=\"summary\">\(h($0))</p>" } ?? "")\(summaryCredit(series, strings: strings))
            \(series.matchStatus == "unmatched" && !spotlight ? "<p class=\"hint\">\(h(strings["unmatched"]))</p>" : "")
            </div></div></section>
            """
    }

    /// Where a synopsis taken from Wikipedia comes from, as its licence asks.
    static func summaryCredit(_ series: SeriesRecord, strings: Strings) -> String {
        guard series.summary != nil, series.match?.summarySource == .wikipedia else { return "" }
        let link = series.match?.summaryURL.map { "<a href=\"\(h($0.absoluteString))\" rel=\"noopener\" target=\"_blank\">Wikipédia</a>" } ?? "Wikipédia"
        return "<p class=\"credit\">\(h(strings["summaryFrom"])) \(link) · CC BY-SA</p>"
    }

    // MARK: - Reader

    /// The reader: a page at a time, two side by side on a wide screen, or a vertical strip; its settings ride on data
    /// attributes, since the page only runs scripts from the server (/reader.js).
    static func readerPage(book: BookRecord, series: SeriesRecord, count: Int, start: Int, next: BookRecord?, rightToLeft: Bool,
                           strings: Strings) -> String {
        let name = strings.bookTitle(book, kind: series.kind)
        let nextLink = next.map { "<a class=\"button\" href=\"/read/\($0.id)?page=0\">\(h(strings["nextBook"])) · \(h(strings.bookTitle($0, kind: series.kind)))</a>" } ?? ""
        let layouts = [("auto", "Auto", "layoutAuto"), ("single", "1", "layoutSingle"), ("double", "2", "layoutDouble"), ("vertical", "↕", "layoutVertical")]
            .map { "<button class=\"link\" data-layout=\"\($0.0)\" title=\"\(h(strings[$0.2]))\" aria-label=\"\(h(strings[$0.2]))\">\($0.1)</button>" }.joined()
        return WebPage.document(title: "\(series.title) · \(name)", language: strings.language, body: """
            <div id="reader" class="chrome" data-book="\(book.id)" data-count="\(count)" data-start="\(start)" data-rtl="\(rightToLeft ? "1" : "0")" data-back="/series/\(series.id)">
            <div id="view"><img id="page" alt=""><img id="page2" alt="" hidden></div><div id="strip" hidden></div>
            <div class="zones"><button class="zone" data-zone="left" aria-label="\(h(strings[rightToLeft ? "nextPage" : "previousPage"]))"></button>\
            <button class="zone" data-zone="middle" aria-label="\(h(strings["menu"]))"></button>\
            <button class="zone" data-zone="right" aria-label="\(h(strings[rightToLeft ? "previousPage" : "nextPage"]))"></button></div>
            <header class="bar top"><a class="back" href="/series/\(series.id)">‹ \(h(series.title))</a><span class="title">\(h(name))</span>\
            <span id="counter"></span><span class="layouts" role="group" aria-label="\(h(strings["layout"]))">\(layouts)</span>\
            <button class="link" id="zoom" title="\(h(strings["zoomHint"]))">\(h(strings["zoom"]))</button>\
            <button class="link" id="fullscreen">\(h(strings["fullScreen"]))</button></header>
            <footer class="bar bottom"><input id="scrub" type="range" min="1" max="\(count)" step="1" dir="\(rightToLeft ? "rtl" : "ltr")" aria-label="\(h(strings["pages"]))"></footer>
            <div id="end" hidden><p>\(h(strings["endOfBook"]))</p><p class="inline">\(nextLink)<a class="button quiet" href="/series/\(series.id)">\(h(strings["backToSeries"]))</a></p></div>
            </div><script src="/reader.js?v=\(WebPage.version(of: readerScript))"></script>
            """, bodyClass: "reader-page")
    }

    /// Turns pages with the arrows, a tap or click on either side, a swipe or the slider; shows two pages side by
    /// side on a wide screen (the cover and wide pages alone, manga right to left), or every page in a vertical strip,
    /// by itself when the pages are long strips (webtoons); zooms with a pinch of the trackpad, + and −, or the button,
    /// and pans by dragging. Keeps the next pages loaded, and saves the page on the server, where the member's other
    /// devices find it. The layout chosen stays in the browser.
    static let readerScript = """
    (function () {
      var root = document.getElementById('reader');
      var book = root.dataset.book, count = parseInt(root.dataset.count, 10), rtl = root.dataset.rtl === '1';
      var index = parseInt(root.dataset.start, 10) || 0;
      var view = document.getElementById('view'), left = document.getElementById('page'), right = document.getElementById('page2');
      var strip = document.getElementById('strip'), counter = document.getElementById('counter');
      var scrub = document.getElementById('scrub'), end = document.getElementById('end');
      var width = Math.min(4000, Math.max(200, Math.round(Math.max(window.innerWidth, window.innerHeight) * (window.devicePixelRatio || 1))));
      var loaded = {}, shape = {}, saving = null, hiding = null;
      var preference = 'auto', mode = 'single', strips = false;
      var zoom = 1, panX = 0, panY = 0;
      try { preference = localStorage.getItem('crs.layout') || 'auto'; } catch (e) {}

      function source(i) { return '/api/v1/books/' + book + '/pages/' + i + '?width=' + width; }
      // A page is wide (a spread already), tall (a strip) or a page; learnt as it loads.
      function learn(i, image) {
        if (!image.naturalWidth || shape[i]) { return; }
        var ratio = image.naturalHeight / image.naturalWidth;
        shape[i] = ratio < 1 ? 'wide' : (ratio > 2.2 ? 'tall' : 'page');
        if (shape[i] === 'tall' && !strips) { strips = true; if (preference === 'auto') { apply(); return; } }
        if (mode === 'double' && shape[i] === 'wide') { render(); }
      }
      function preload(i) {
        if (i < 0 || i >= count || loaded[i]) { return; }
        var image = new Image();
        loaded[i] = image;
        image.onload = function () { learn(i, image); };
        image.src = source(i);
      }
      function save(page) {
        clearTimeout(saving);
        saving = setTimeout(function () {
          fetch('/api/v1/books/' + book + '/progress', {
            method: 'PUT', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ page: page, finished: page >= count - 1, fraction: count > 1 ? page / (count - 1) : 1,
                                   updatedAt: new Date().toISOString() })
          }).catch(function () {});
        }, 700);
      }
      function chosenMode() {
        if (preference !== 'auto') { return preference; }
        if (strips) { return 'vertical'; }
        return window.innerWidth >= 900 && window.innerWidth > window.innerHeight * 1.15 ? 'double' : 'single';
      }
      // The cover alone, then pages two by two; a wide page always alone.
      function spreadOf(i) {
        if (mode !== 'double' || i === 0) { return [i]; }
        var page = 1;
        while (page < count) {
          var pair = shape[page] !== 'wide' && page + 1 < count && shape[page + 1] !== 'wide';
          if (i === page || (pair && i === page + 1)) { return pair ? [page, page + 1] : [page]; }
          page += pair ? 2 : 1;
        }
        return [i];
      }
      function render() {
        var pages = spreadOf(index);
        index = pages[0];
        var a = pages[0], b = pages.length > 1 ? pages[1] : null;
        resetZoom();
        // Manga read right to left: the first page of a spread goes on the right.
        left.src = source(b === null || !rtl ? a : b);
        if (b === null) { right.hidden = true; right.removeAttribute('src'); } else { right.hidden = false; right.src = source(rtl ? a : b); }
        view.classList.toggle('spread', b !== null);
        var last = b === null ? a : b;
        counter.textContent = (b === null ? (a + 1) : (a + 1) + '-' + (b + 1)) + ' / ' + count;
        scrub.value = a + 1;
        [a, b, last + 1, last + 2, last + 3, a - 1, a - 2].forEach(function (page) { if (page !== null) { preload(page); } });
        save(last);
      }
      function show(i) {
        if (i < 0) { return; }
        if (i >= count) { end.hidden = false; return; }
        end.hidden = true;
        index = i;
        if (mode === 'vertical') { var image = strip.children[i]; if (image) { image.scrollIntoView({ block: 'start' }); } return; }
        render();
      }
      function forward() {
        if (mode === 'vertical') { strip.scrollBy({ top: strip.clientHeight * 0.85, behavior: 'smooth' }); return; }
        var pages = spreadOf(index);
        show(pages[pages.length - 1] + 1);
      }
      function backward() {
        if (!end.hidden) { end.hidden = true; return; }
        if (mode === 'vertical') { strip.scrollBy({ top: -strip.clientHeight * 0.85, behavior: 'smooth' }); return; }
        if (index > 0) { show(spreadOf(index - 1)[0]); }
      }
      // The strip: every page, loaded as it comes near; the page in the middle of the screen is the one read.
      function buildStrip() {
        if (strip.childElementCount) { return; }
        for (var i = 0; i < count; i++) {
          var image = document.createElement('img');
          image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.src = source(i);
          strip.appendChild(image);
        }
        var ticking = false;
        strip.addEventListener('scroll', function () {
          if (ticking) { return; }
          ticking = true;
          // A timer rather than an animation frame, which a hidden tab doesn't run.
          setTimeout(function () {
            ticking = false;
            var middle = strip.clientHeight / 2, images = strip.children;
            for (var k = 0; k < images.length; k++) {
              var box = images[k].getBoundingClientRect();
              if (box.top <= middle && box.bottom >= middle) {
                if (k !== index) { index = k; counter.textContent = (k + 1) + ' / ' + count; scrub.value = k + 1; }
                break;
              }
            }
            var atEnd = strip.scrollTop + strip.clientHeight >= strip.scrollHeight - 4;
            save(atEnd ? count - 1 : index);
          }, 120);
        });
      }
      function apply() {
        mode = chosenMode();
        root.dataset.mode = mode;
        document.querySelectorAll('[data-layout]').forEach(function (button) {
          button.setAttribute('aria-pressed', button.dataset.layout === preference ? 'true' : 'false');
        });
        if (mode === 'vertical') {
          view.hidden = true; strip.hidden = false; buildStrip();
          var image = strip.children[index]; if (image) { image.scrollIntoView({ block: 'start' }); }
          counter.textContent = (index + 1) + ' / ' + count;
        } else {
          strip.hidden = true; view.hidden = false; render();
        }
      }
      function chrome(visible) {
        root.classList.toggle('chrome', visible);
        clearTimeout(hiding);
        if (visible) { hiding = setTimeout(function () { root.classList.remove('chrome'); }, 3500); }
      }
      // Zoom: the page view scaled around a point, then dragged; the zones are off while it is zoomed.
      function setZoom(value, x, y) {
        var next = Math.min(4, Math.max(1, value));
        if (x === undefined) { x = window.innerWidth / 2; y = window.innerHeight / 2; }
        panX = x - (x - panX) * next / zoom; panY = y - (y - panY) * next / zoom;
        zoom = next;
        if (zoom === 1) { panX = 0; panY = 0; }
        view.style.transform = zoom === 1 ? '' : 'translate(' + panX + 'px, ' + panY + 'px) scale(' + zoom + ')';
        root.classList.toggle('zoomed', zoom > 1);
      }
      function resetZoom() { if (zoom !== 1) { setZoom(1); } }
      view.style.transformOrigin = '0 0';
      window.addEventListener('wheel', function (event) {
        if (!event.ctrlKey || mode === 'vertical') { return; }
        event.preventDefault();
        setZoom(zoom * Math.exp(-event.deltaY / 120), event.clientX, event.clientY);
      }, { passive: false });
      var drag = null;
      view.addEventListener('pointerdown', function (event) {
        if (zoom === 1) { return; }
        drag = { x: event.clientX - panX, y: event.clientY - panY };
        view.setPointerCapture(event.pointerId);
      });
      view.addEventListener('pointermove', function (event) {
        if (!drag) { return; }
        panX = event.clientX - drag.x; panY = event.clientY - drag.y;
        view.style.transform = 'translate(' + panX + 'px, ' + panY + 'px) scale(' + zoom + ')';
      });
      view.addEventListener('pointerup', function () { drag = null; });
      view.addEventListener('dblclick', function () { resetZoom(); });
      document.getElementById('zoom').addEventListener('click', function () { setZoom(zoom > 1 ? 1 : 2); chrome(true); });

      document.querySelectorAll('.zone').forEach(function (zone) {
        zone.addEventListener('click', function () {
          var side = zone.dataset.zone;
          if (side === 'middle') { chrome(!root.classList.contains('chrome')); return; }
          if ((side === 'right') !== rtl) { forward(); } else { backward(); }
        });
      });
      strip.addEventListener('click', function () { chrome(!root.classList.contains('chrome')); });
      document.querySelectorAll('[data-layout]').forEach(function (button) {
        button.addEventListener('click', function () {
          preference = button.dataset.layout;
          try { localStorage.setItem('crs.layout', preference); } catch (e) {}
          apply(); chrome(true);
        });
      });
      document.addEventListener('keydown', function (event) {
        if (event.target === scrub) { return; }
        switch (event.key) {
          case 'ArrowRight': rtl ? backward() : forward(); break;
          case 'ArrowLeft': rtl ? forward() : backward(); break;
          case ' ': case 'PageDown': case 'ArrowDown': forward(); break;
          case 'PageUp': case 'ArrowUp': backward(); break;
          case 'Home': show(0); break;
          case 'End': show(count - 1); break;
          case 'f': toggleFullscreen(); break;
          case '+': case '=': setZoom(zoom * 1.5); break;
          case '-': setZoom(zoom / 1.5); break;
          case '0': setZoom(1); break;
          case 'Escape':
            if (zoom > 1) { setZoom(1); return; }
            if (!document.fullscreenElement) { location.href = root.dataset.back; }
            return;
          default: return;
        }
        event.preventDefault();
      });
      var startX = null;
      root.addEventListener('touchstart', function (event) { startX = event.touches.length === 1 ? event.touches[0].clientX : null; }, { passive: true });
      root.addEventListener('touchend', function (event) {
        if (startX === null || event.changedTouches.length !== 1 || mode === 'vertical' || zoom > 1) { return; }
        var moved = event.changedTouches[0].clientX - startX;
        startX = null;
        if (Math.abs(moved) < 50) { return; }
        if ((moved < 0) !== rtl) { forward(); } else { backward(); }
      });
      scrub.addEventListener('input', function () { counter.textContent = scrub.value + ' / ' + count; chrome(true); });
      scrub.addEventListener('change', function () { show(parseInt(scrub.value, 10) - 1); });
      function toggleFullscreen() {
        if (document.fullscreenElement) { document.exitFullscreen(); } else if (root.requestFullscreen) { root.requestFullscreen(); }
      }
      var fullscreen = document.getElementById('fullscreen');
      if (root.requestFullscreen) { fullscreen.addEventListener('click', toggleFullscreen); } else { fullscreen.hidden = true; }
      window.addEventListener('resize', function () { if (preference === 'auto' && chosenMode() !== mode) { apply(); } });
      index = Math.min(Math.max(index, 0), count - 1);
      preload(index);
      apply();
      chrome(true);
    })();
    """
}
