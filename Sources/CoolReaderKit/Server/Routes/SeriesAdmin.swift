import Foundation
import NIOHTTP1

/// The admin's hand on a series' metadata, in the web pages and in the API: another catalogue entry chosen from a
/// search of their own, the matcher asked again, no metadata at all, or a title and synopsis of their own.
nonisolated enum SeriesAdminRoutes {
    struct Choice: Decodable {
        var source: String
        var id: String
    }

    /// Fields left out stay as they are; an empty string gives the catalogues' back.
    struct Edit: Decodable {
        var title: String?
        var summary: String?
    }

    static func add(to router: inout Router, context: ServerContext) {
        // MARK: Web

        router.add(.GET, "/series/:id/match") { request in
            let caller = try await AdminRoutes.adminPage(request, context)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            let strings = Strings(request.language)
            let query = request.query["q"] ?? series.title
            var page = WebPage(title: strings.matchPageTitle(series.title), strings: strings, caller: caller,
                               libraries: context.store.visibleLibraries(for: caller.user), section: "/library/\(series.libraryID)")
            page.add("<p class=\"back\"><a href=\"/series/\(series.id)\">‹ \(h(series.title))</a></p><h1>\(h(strings.matchPageTitle(series.title)))</h1>")
            page.add("<p class=\"hint\">\(h(currentState(series, strings: strings)))</p>")
            page.add("""
                <div class="inline"><form method="post" action="/series/\(series.id)/rematch"><button class="quiet">\(h(strings["rematch"]))</button></form>\
                <form method="post" action="/series/\(series.id)/unmatch"><button class="quiet danger">\(h(strings["unmatch"]))</button></form></div>
                <h2>\(h(strings["searchCatalogues"]))</h2>
                <form class="inline wide" method="get" action="/series/\(series.id)/match"><input name="q" value="\(h(query))" required>\
                <button>\(h(strings["search"]))</button></form>
                """)
            let candidates = await SeriesMatcher.candidates(for: query)
            if candidates.isEmpty {
                page.add("<p class=\"empty\">\(h(strings["noCandidates"]))</p>")
            } else {
                page.add("<div class=\"candidates\">" + candidates.map { candidateRow($0, series: series, strings: strings) }.joined() + "</div>")
            }
            page.add("""
                <h2 id="edit">\(h(strings["editSeries"]))</h2>
                <form class="stack" method="post" action="/series/\(series.id)/edit">
                <label>\(h(strings["customTitle"]))<input name="title" value="\(h(series.customTitle ?? ""))" placeholder="\(h(series.match?.title ?? series.folderTitle))" maxlength="200"></label>
                <label>\(h(strings["customSummary"]))<textarea name="summary" rows="6" maxlength="6000" placeholder="\(h(series.match?.summary.map { String($0.prefix(200)) } ?? ""))">\(h(series.customSummary ?? ""))</textarea></label>
                <p class="hint">\(h(strings["customHint"]))</p>
                <button>\(h(strings["save"]))</button></form>
                """)
            return .html(page.html)
        }

        router.add(.POST, "/series/:id/match") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try await choose(Choice(source: request.form["source"] ?? "", id: request.form["id"] ?? ""), for: series, context: context)
            return .redirect("/series/\(series.id)")
        }

        router.add(.POST, "/series/:id/rematch") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try await rematch(series, context: context)
            return .redirect("/series/\(series.id)")
        }

        router.add(.POST, "/series/:id/unmatch") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try context.store.setMatch(seriesID: series.id, status: "ignored", match: nil)
            return .redirect("/series/\(series.id)")
        }

        router.add(.POST, "/series/:id/edit") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try edit(series, Edit(title: request.form["title"], summary: request.form["summary"]), context: context)
            return .redirect("/series/\(series.id)")
        }

        // The pages only load images from the server: a candidate's cover comes through it, from the catalogues alone.
        router.add(.GET, "/catalog-image") { request in
            _ = try await AdminRoutes.adminPage(request, context)
            guard let address = request.query["u"], let url = URL(string: address), url.scheme == "https",
                  let host = url.host?.lowercased(), catalogueHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  let image = await context.images.remoteImage(url) else { throw HTTPError.notFound }
            return .image(image.data, contentType: image.contentType)
        }

        // MARK: API

        router.add(.GET, "/api/v1/admin/series/:id/candidates") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            return .json(await SeriesMatcher.candidates(for: request.query["q"] ?? series.title))
        }

        router.add(.POST, "/api/v1/admin/series/:id/match") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try await choose(try APIRoutes.decode(Choice.self, request), for: series, context: context)
            return try detail(series.id, caller: caller, context: context)
        }

        router.add(.POST, "/api/v1/admin/series/:id/rematch") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try await rematch(series, context: context)
            return try detail(series.id, caller: caller, context: context)
        }

        router.add(.POST, "/api/v1/admin/series/:id/unmatch") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try context.store.setMatch(seriesID: series.id, status: "ignored", match: nil)
            return try detail(series.id, caller: caller, context: context)
        }

        router.add(.PATCH, "/api/v1/admin/series/:id") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            try edit(series, try APIRoutes.decode(Edit.self, request), context: context)
            return try detail(series.id, caller: caller, context: context)
        }
    }

    static let catalogueHosts = ["anilist.co", "mzstatic.com", "openlibrary.org", "comicvine.gamespot.com", "wikimedia.org", "mangadex.org"]

    // MARK: - Actions

    /// Applies the catalogue entry the admin chose; the matcher never replaces it.
    static func choose(_ choice: Choice, for series: SeriesRecord, context: ServerContext) async throws {
        guard let source = SeriesMatch.Source(rawValue: choice.source), !choice.id.isEmpty else {
            throw HTTPError.badRequest("Choose a catalogue entry: a source and its id.")
        }
        let input = MetadataAgent.input(for: series, books: context.store.books(seriesID: series.id))
        guard let match = try await SeriesMatcher.apply(candidate: choice.id, source: source, to: input) else {
            throw HTTPError(status: .notFound, message: "This catalogue entry can't be found any more.")
        }
        try context.store.setMatch(seriesID: series.id, status: "manual", match: match)
        Log.info("« \(series.folderTitle) »: matched by hand on \(source.rawValue).")
    }

    static func rematch(_ series: SeriesRecord, context: ServerContext) async throws {
        try context.store.rematch(seriesID: series.id)
        await context.agent.wake()
    }

    static func edit(_ series: SeriesRecord, _ edit: Edit, context: ServerContext) throws {
        func value(_ field: String?, current: String?, limit: Int) -> String? {
            guard let field else { return current }
            let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
        }
        try context.store.setCustom(seriesID: series.id, title: value(edit.title, current: series.customTitle, limit: 200),
                                    summary: value(edit.summary, current: series.customSummary, limit: 6000))
    }

    private static func detail(_ id: Int, caller: Caller, context: ServerContext) throws -> Response {
        let (series, _) = try context.visibleSeries(id, for: caller)
        let progress = context.store.progress(userID: caller.user.id, seriesID: series.id)
        return .json(APIRoutes.SeriesDetail(series: APIRoutes.info(series),
                                            books: context.store.books(seriesID: series.id).map { APIRoutes.info($0, progress: progress[$0.id]) }))
    }

    // MARK: - Pieces

    static func sourceName(_ source: SeriesMatch.Source) -> String {
        switch source {
        case .anilist: "AniList"
        case .mangadex: "MangaDex"
        case .appleBooks: "Apple Books"
        case .openLibrary: "Open Library"
        case .comicVine: "Comic Vine"
        case .wikipedia: "Wikipédia"
        }
    }

    private static func currentState(_ series: SeriesRecord, strings: Strings) -> String {
        let source = series.match.map { sourceName($0.source) }
        switch series.matchStatus {
        case "manual": return strings["manualMatch"] + (source.map { " · \($0)" } ?? "")
        case "ignored": return strings["ignoredMatch"]
        case "unmatched": return strings["notMatched"]
        case "pending": return strings["matching"]
        default: return source.map { "\(strings["matchedOn"]) \($0)" } ?? strings["notMatched"]
        }
    }

    private static func candidateRow(_ candidate: MatchCandidate, series: SeriesRecord, strings: Strings) -> String {
        let cover = candidate.coverURL.map { url in
            "<img src=\"/catalog-image?u=\(h(url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))\" alt=\"\" loading=\"lazy\">"
        } ?? "<span class=\"no-cover\">\(Icon.books)</span>"
        let facts = [sourceName(candidate.source), candidate.year.map(String.init), candidate.detail].compactMap { $0 }.filter { !$0.isEmpty }
        let current = series.match?.source == candidate.source
            && (series.match?.catalogID == candidate.id || (candidate.source == .anilist && series.match?.anilistID.map(String.init) == candidate.id))
        return """
            <form class="candidate\(current ? " current" : "")" method="post" action="/series/\(series.id)/match">\
            <input type="hidden" name="source" value="\(candidate.source.rawValue)"><input type="hidden" name="id" value="\(h(candidate.id))">\
            <span class="art">\(cover)</span><span class="what"><strong>\(h(candidate.title))</strong><span class="sub">\(h(facts.joined(separator: " · ")))</span>\
            \(candidate.summary.map { "<span class=\"excerpt\">\(h(String($0.prefix(260))))</span>" } ?? "")</span>\
            <button class="quiet">\(h(strings[current ? "chosen" : "choose"]))</button></form>
            """
    }
}
