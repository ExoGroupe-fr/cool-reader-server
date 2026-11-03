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
            var page = WebPage(title: context.serverName, strings: strings, caller: caller, section: "/")
            let libraries = context.store.visibleLibraries(for: caller.user)
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
            let readingCards = reading.compactMap { item -> String? in
                guard let series = context.store.series(id: item.book.seriesID) else { return nil }
                return bookCard(item.book, series: series, progress: item.progress, strings: strings, showSeries: true)
            }
            if !readingCards.isEmpty { page.add(shelf(strings["continueReading"], cards: readingCards, strings: strings)) }
            let recent = context.store.recentSeries(libraryIDs: libraries.map(\.id), limit: 20)
            if libraries.count > 1, !recent.isEmpty {
                page.add(shelf(strings["recent"], cards: recent.map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) },
                               strings: strings))
            }
            for library in libraries {
                let series = context.store.series(libraryID: library.id)
                let cards = series.prefix(24).map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) }
                page.add(shelf(library.name, detail: strings.seriesCount(library.seriesCount), link: "/library/\(library.id)",
                               cards: Array(cards), empty: strings["noSeries"], strings: strings))
            }
            page.add("<p class=\"hint\">\(h(strings["opdsHint"])) <code>\(h(AdminRoutes.host(request)))/opds</code> \(h(strings["opdsHint2"]))</p>")
            return .html(page.html)
        }

        router.add(.GET, "/library/:id") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let library = try context.visibleLibrary(request.parameter("id"), for: caller)
            let strings = Strings(request.language)
            let byDate = request.query["sort"] == "recent"
            var page = WebPage(title: library.name, strings: strings, caller: caller, section: "/library/\(library.id)")
            page.add("""
                <div class="heading"><h1>\(h(library.name)) <small>\(h(strings.seriesCount(library.seriesCount)))</small></h1>
                <p class="sort"><a href="/library/\(library.id)"\(byDate ? "" : " aria-current=\"true\"")>\(h(strings["sortTitle"]))</a>
                <a href="/library/\(library.id)?sort=recent"\(byDate ? " aria-current=\"true\"" : "")>\(h(strings["recent"]))</a></p></div>
                """)
            var series = context.store.series(libraryID: library.id)
            if byDate { series.sort { $0.addedAt > $1.addedAt } }
            let finished = context.store.finishedCounts(userID: caller.user.id)
            page.add(series.isEmpty ? "<p class=\"empty\">\(h(strings["noSeries"]))</p>"
                                    : grid(series.map { seriesCard($0, finished: finished[$0.id] ?? 0, strings: strings) }))
            return .html(page.html)
        }

        router.add(.GET, "/search") { request in
            guard let caller = await context.caller(request) else { return .redirect("/login") }
            let strings = Strings(request.language)
            let text = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var page = WebPage(title: strings["search"], strings: strings, caller: caller, search: text)
            page.add("<h1>\(h(text.isEmpty ? strings["search"] : strings.searchTitle(text)))</h1>")
            let results = context.store.searchSeries(text, libraryIDs: context.visibleLibraryIDs(for: caller))
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
            var page = WebPage(title: series.title, strings: strings, caller: caller, section: "/library/\(series.libraryID)")
            page.add(hero(series, books: books, progress: progress, strings: strings))
            let cards = books.map { book in
                bookCard(book, series: series, progress: progress[book.id], strings: strings, showSeries: false, actions: true)
            }
            page.add("<h2>\(h(strings.bookCount(books.count, kind: series.kind)))</h2>")
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

    static func shelf(_ title: String, detail: String? = nil, link: String? = nil, cards: [String], empty: String? = nil,
                      strings: Strings) -> String {
        let heading = link.map { "<a href=\"\($0)\">\(h(title))</a>" } ?? h(title)
        let more = link.map { "<a class=\"more\" href=\"\($0)\">\(h(strings["seeAll"])) ›</a>" } ?? ""
        let body = cards.isEmpty ? "<p class=\"empty\">\(h(empty ?? ""))</p>" : "<div class=\"shelf\">\(cards.joined())</div>"
        return "<section class=\"row-section\"><div class=\"row-head\"><h2>\(heading)\(detail.map { " <small>\(h($0))</small>" } ?? "")</h2>\(more)</div>\(body)</section>"
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
                         actions: Bool = false) -> String {
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
                <button class="link">\(h(strings[finished ? "markUnread" : "markRead"]))</button></form></span>
                """
        }
        return """
            <div class="card" id="book-\(book.id)"><a href="\(href)"><span class="art"><img src="/api/v1/books/\(book.id)/cover" alt="" loading="lazy">\(state)</span>\
            <strong>\(h(showSeries ? series.title : name))</strong><span class="sub">\(h(sub.joined(separator: " · ")))</span></a>\(tools)</div>
            """
    }

    /// The top of a series' page: its banner (or its poster, blurred), poster, facts and the button that reads on.
    static func hero(_ series: SeriesRecord, books: [BookRecord], progress: [Int: ProgressRecord], strings: Strings) -> String {
        let hasBanner = series.bannerPath != nil || series.match?.bannerURL != nil
        let backdrop = hasBanner ? "/api/v1/series/\(series.id)/banner" : "/api/v1/series/\(series.id)/cover"
        let facts = [series.authors.joined(separator: ", "), series.year.map(String.init), series.status.map { strings[$0] },
                     strings.bookCount(series.bookCount, kind: series.kind)].compactMap { $0 }.filter { !$0.isEmpty }
        let genres = series.genres.map { "<span class=\"chip\">\(h(strings.genre($0)))</span>" }.joined()
        let readable = books.filter(isReadableOnline)
        var action = ""
        if let next = readable.first(where: { progress[$0.id]?.finished != true }) {
            let started = (progress[next.id]?.page ?? 0) > 0
            let label = started ? strings["resume"] : strings["read"]
            let name = readable.count > 1 ? " · \(strings.bookTitle(next, kind: series.kind))" : ""
            action = "<a class=\"button play\" href=\"/read/\(next.id)\">▶ \(h(label + name))</a>"
        } else if let first = readable.first {
            action = "<a class=\"button play\" href=\"/read/\(first.id)?page=0\">▶ \(h(strings["readAgain"]))</a>"
        }
        return """
            <section class="hero\(hasBanner ? " banner" : "")"><div class="backdrop" style="background-image: url('\(backdrop)')"></div>
            <div class="hero-body"><img class="poster" src="/api/v1/series/\(series.id)/cover" alt="">
            <div class="info"><h1>\(h(series.title))</h1><p class="facts">\(h(facts.joined(separator: " · ")))</p>
            \(genres.isEmpty ? "" : "<p class=\"chips\">\(genres)</p>")\(action.isEmpty ? "" : "<p class=\"actions\">\(action)</p>")
            \(series.summary.map { "<p class=\"summary\">\(h($0))</p>" } ?? "")
            \(series.matchStatus == "unmatched" ? "<p class=\"hint\">\(h(strings["unmatched"]))</p>" : "")
            </div></div></section>
            """
    }

    // MARK: - Reader

    /// The reader: one page at a time, fitted to the window. Its settings ride on data attributes, since the page
    /// only runs scripts from the server (/reader.js).
    static func readerPage(book: BookRecord, series: SeriesRecord, count: Int, start: Int, next: BookRecord?, rightToLeft: Bool,
                           strings: Strings) -> String {
        let name = strings.bookTitle(book, kind: series.kind)
        let nextLink = next.map { "<a class=\"button\" href=\"/read/\($0.id)?page=0\">\(h(strings["nextBook"])) · \(h(strings.bookTitle($0, kind: series.kind)))</a>" } ?? ""
        return WebPage.document(title: "\(series.title) · \(name)", language: strings.language, body: """
            <div id="reader" class="chrome" data-book="\(book.id)" data-count="\(count)" data-start="\(start)" data-rtl="\(rightToLeft ? "1" : "0")" data-back="/series/\(series.id)">
            <img id="page" alt="">
            <div class="zones"><button class="zone" data-zone="left" aria-label="\(h(strings[rightToLeft ? "nextPage" : "previousPage"]))"></button>\
            <button class="zone" data-zone="middle" aria-label="\(h(strings["menu"]))"></button>\
            <button class="zone" data-zone="right" aria-label="\(h(strings[rightToLeft ? "previousPage" : "nextPage"]))"></button></div>
            <header class="bar top"><a class="back" href="/series/\(series.id)">‹ \(h(series.title))</a><span class="title">\(h(name))</span>\
            <span id="counter"></span><button class="link" id="fullscreen">\(h(strings["fullScreen"]))</button></header>
            <footer class="bar bottom"><input id="scrub" type="range" min="1" max="\(count)" step="1" dir="\(rightToLeft ? "rtl" : "ltr")" aria-label="\(h(strings["pages"]))"></footer>
            <div id="end" hidden><p>\(h(strings["endOfBook"]))</p><p class="inline">\(nextLink)<a class="button quiet" href="/series/\(series.id)">\(h(strings["backToSeries"]))</a></p></div>
            </div><script src="/reader.js?v=\(WebPage.version(of: readerScript))"></script>
            """, bodyClass: "reader-page")
    }

    /// Turns pages with the arrows, a tap or click on either side, a swipe or the slider; keeps the next pages
    /// loaded; saves the page on the server, where the member's other devices find it.
    static let readerScript = """
    (function () {
      var root = document.getElementById('reader');
      var book = root.dataset.book, count = parseInt(root.dataset.count, 10), rtl = root.dataset.rtl === '1';
      var index = parseInt(root.dataset.start, 10) || 0;
      var image = document.getElementById('page'), counter = document.getElementById('counter');
      var scrub = document.getElementById('scrub'), end = document.getElementById('end');
      var width = Math.min(4000, Math.max(200, Math.round(Math.max(window.innerWidth, window.innerHeight) * (window.devicePixelRatio || 1))));
      var loaded = {}, saving = null, hiding = null;
      function source(i) { return '/api/v1/books/' + book + '/pages/' + i + '?width=' + width; }
      function preload(i) { if (i >= 0 && i < count && !loaded[i]) { loaded[i] = new Image(); loaded[i].src = source(i); } }
      function save() {
        clearTimeout(saving);
        saving = setTimeout(function () {
          fetch('/api/v1/books/' + book + '/progress', {
            method: 'PUT', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ page: index, finished: index >= count - 1, fraction: count > 1 ? index / (count - 1) : 1,
                                   updatedAt: new Date().toISOString() })
          }).catch(function () {});
        }, 700);
      }
      function show(i) {
        if (i < 0) { return; }
        if (i >= count) { end.hidden = false; return; }
        end.hidden = true;
        index = i;
        image.src = source(i);
        counter.textContent = (i + 1) + ' / ' + count;
        scrub.value = i + 1;
        preload(i + 1); preload(i + 2); preload(i - 1);
        save();
      }
      function forward() { show(index + 1); }
      function backward() { if (!end.hidden) { end.hidden = true; return; } show(index - 1); }
      function chrome(visible) {
        root.classList.toggle('chrome', visible);
        clearTimeout(hiding);
        if (visible) { hiding = setTimeout(function () { root.classList.remove('chrome'); }, 3500); }
      }
      document.querySelectorAll('.zone').forEach(function (zone) {
        zone.addEventListener('click', function () {
          var side = zone.dataset.zone;
          if (side === 'middle') { chrome(!root.classList.contains('chrome')); return; }
          if ((side === 'right') !== rtl) { forward(); } else { backward(); }
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
          case 'Escape': if (!document.fullscreenElement) { location.href = root.dataset.back; } return;
          default: return;
        }
        event.preventDefault();
      });
      var startX = null;
      root.addEventListener('touchstart', function (event) { startX = event.touches.length === 1 ? event.touches[0].clientX : null; }, { passive: true });
      root.addEventListener('touchend', function (event) {
        if (startX === null || event.changedTouches.length !== 1) { return; }
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
      show(Math.min(Math.max(index, 0), count - 1));
      chrome(true);
    })();
    """
}
