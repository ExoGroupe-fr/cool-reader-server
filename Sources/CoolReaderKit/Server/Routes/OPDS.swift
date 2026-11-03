import Foundation
import NIOHTTP1

/// OPDS 1.2 catalogues, with the Page Streaming Extension: readers like Panels, Chunky or KOReader browse the
/// libraries, download books and read image books page by page. They sign in with a member's name and password.
nonisolated enum OPDSRoutes {
    static let navigation = "application/atom+xml;profile=opds-catalog;kind=navigation"
    static let acquisition = "application/atom+xml;profile=opds-catalog;kind=acquisition"

    static func add(to router: inout Router, context: ServerContext) {
        router.add(.GET, "/opds") { _ in .redirect("/opds/v1.2/catalog") }

        router.add(.GET, "/opds/v1.2/catalog") { request in
            guard let caller = await context.caller(request) else { return challenge(context) }
            let strings = Strings(request.language)
            var feed = Feed(id: "urn:coolreader:\(context.serverID):catalog", title: context.config.serverName,
                            selfLink: "/opds/v1.2/catalog", kind: navigation)
            for library in context.store.visibleLibraries(for: caller.user) {
                feed.entries.append(Entry(id: "urn:coolreader:library:\(library.id)", title: library.name,
                                          content: strings.seriesCount(library.seriesCount),
                                          links: [Link(rel: "subsection", href: "/opds/v1.2/libraries/\(library.id)", type: navigation)]))
            }
            feed.entries.append(Entry(id: "urn:coolreader:\(context.serverID):recent", title: strings["recent"],
                                      links: [Link(rel: "subsection", href: "/opds/v1.2/recent", type: navigation)]))
            return .xml(feed.xml, contentType: navigation)
        }

        router.add(.GET, "/opds/v1.2/libraries/:id") { request in
            guard let caller = await context.caller(request) else { return challenge(context) }
            let library = try context.visibleLibrary(request.parameter("id"), for: caller)
            var feed = Feed(id: "urn:coolreader:library:\(library.id)", title: library.name,
                            selfLink: "/opds/v1.2/libraries/\(library.id)", kind: navigation)
            feed.entries = context.store.series(libraryID: library.id).map { entry(for: $0, strings: Strings(request.language)) }
            return .xml(feed.xml, contentType: navigation)
        }

        router.add(.GET, "/opds/v1.2/recent") { request in
            guard let caller = await context.caller(request) else { return challenge(context) }
            var feed = Feed(id: "urn:coolreader:\(context.serverID):recent", title: Strings(request.language)["recent"],
                            selfLink: "/opds/v1.2/recent", kind: navigation)
            feed.entries = context.store.recentSeries(libraryIDs: context.visibleLibraryIDs(for: caller), limit: 50)
                .map { entry(for: $0, strings: Strings(request.language)) }
            return .xml(feed.xml, contentType: navigation)
        }

        router.add(.GET, "/opds/v1.2/series/:id") { request in
            guard let caller = await context.caller(request) else { return challenge(context) }
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            let strings = Strings(request.language)
            var feed = Feed(id: "urn:coolreader:series:\(series.id)", title: series.title,
                            selfLink: "/opds/v1.2/series/\(series.id)", kind: acquisition)
            for book in context.store.books(seriesID: series.id) {
                var links = [
                    Link(rel: "http://opds-spec.org/image", href: "/api/v1/books/\(book.id)/cover", type: "image/jpeg"),
                    Link(rel: "http://opds-spec.org/image/thumbnail", href: "/api/v1/books/\(book.id)/cover", type: "image/jpeg"),
                    Link(rel: "http://opds-spec.org/acquisition", href: "/api/v1/books/\(book.id)/file", type: book.format.mediaType,
                         length: book.fileSize),
                ]
                if let count = book.pageCount, !book.pagePaths.isEmpty || book.format == .pdf {
                    links.append(Link(rel: "http://vaemendis.net/opds-pse/stream",
                                      href: "/api/v1/books/\(book.id)/pages/{pageNumber}?width={maxWidth}", type: "image/jpeg",
                                      pageCount: count))
                }
                feed.entries.append(Entry(id: "urn:coolreader:book:\(book.id)", title: strings.bookTitle(book, kind: series.kind),
                                          authors: series.authors, content: book.metadata?.summary, links: links))
            }
            return .xml(feed.xml, contentType: acquisition)
        }
    }

    private static func entry(for series: SeriesRecord, strings: Strings) -> Entry {
        Entry(id: "urn:coolreader:series:\(series.id)", title: series.title, authors: series.authors,
              content: series.summary ?? strings.bookCount(series.bookCount, kind: series.kind),
              links: [
                  Link(rel: "subsection", href: "/opds/v1.2/series/\(series.id)", type: acquisition),
                  Link(rel: "http://opds-spec.org/image", href: "/api/v1/series/\(series.id)/cover", type: "image/jpeg"),
                  Link(rel: "http://opds-spec.org/image/thumbnail", href: "/api/v1/series/\(series.id)/cover", type: "image/jpeg"),
              ])
    }

    /// Asks the reader for a name and password.
    private static func challenge(_ context: ServerContext) -> Response {
        var response = Response.error(.unauthorized, "Sign in first.")
        response.headers.add(name: "WWW-Authenticate", value: "Basic realm=\"\(context.config.serverName)\", charset=\"UTF-8\"")
        return response
    }

    struct Link {
        var rel: String
        var href: String
        var type: String
        var length: Int64?
        var pageCount: Int?
    }

    struct Entry {
        var id: String
        var title: String
        var authors: [String] = []
        var content: String?
        var links: [Link]
    }

    struct Feed {
        var id: String
        var title: String
        var selfLink: String
        var kind: String
        var entries: [Entry] = []

        var xml: String {
            let updated = ISO8601DateFormatter().string(from: Date())
            var xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" \
                xmlns:pse="http://vaemendis.net/opds-pse/ns">
                <id>\(escape(id))</id><title>\(escape(title))</title><updated>\(updated)</updated>
                <author><name>Cool Reader Server</name></author>
                <link rel="self" href="\(escape(selfLink))" type="\(kind)"/>
                <link rel="start" href="/opds/v1.2/catalog" type="\(OPDSRoutes.navigation)"/>

                """
            for entry in entries {
                xml += "<entry><id>\(escape(entry.id))</id><title>\(escape(entry.title))</title><updated>\(updated)</updated>"
                for author in entry.authors { xml += "<author><name>\(escape(author))</name></author>" }
                if let content = entry.content { xml += "<content type=\"text\">\(escape(content))</content>" }
                for link in entry.links {
                    xml += "<link rel=\"\(escape(link.rel))\" href=\"\(escape(link.href))\" type=\"\(escape(link.type))\""
                    if let length = link.length { xml += " length=\"\(length)\"" }
                    if let count = link.pageCount { xml += " pse:count=\"\(count)\"" }
                    xml += "/>"
                }
                xml += "</entry>\n"
            }
            return xml + "</feed>\n"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
