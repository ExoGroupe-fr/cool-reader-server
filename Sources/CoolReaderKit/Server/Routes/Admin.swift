import Crypto
import Foundation
import NIOHTTP1

/// The web pages: the first start, signing in, the libraries for every member, and for the admin the
/// libraries' folders, the members and their devices.
nonisolated enum AdminRoutes {
    static func add(to router: inout Router, context: ServerContext) {
        router.add(.GET, "/style.css") { _ in
            var response = Response(contentType: "text/css; charset=utf-8", data: Data(WebPage.css.utf8))
            response.headers.add(name: "Cache-Control", value: "public, max-age=3600")
            return response
        }

        // MARK: First start and signing in

        router.add(.GET, "/setup") { request in
            guard await context.setup.isNeeded else { return .redirect("/") }
            return .html(setupPage(Strings(request.language), message: request.query["error"]))
        }

        router.add(.POST, "/setup") { request in
            try checkOrigin(request)
            guard await context.setup.isNeeded else { return .redirect("/") }
            let form = request.form
            let name = (form["name"] ?? "").trimmingCharacters(in: .whitespaces)
            let password = form["password"] ?? ""
            guard await context.setup.matches(form["code"] ?? "") else { return .redirect("/setup?error=wrongSetupCode") }
            if let problem = problem(name: name, password: password, again: form["again"]) { return .redirect("/setup?error=\(problem)") }
            let id = try context.store.createUser(name: name, passwordHash: Passwords.hash(password), isAdmin: true,
                                                  allLibraries: true, libraryIDs: [])
            await context.setup.finish()
            Log.info("The admin account « \(name) » is created.")
            guard let user = context.store.user(id: id) else { throw HTTPError.notFound }
            return signedIn(try context.issueToken(for: user, deviceName: browserName(request), kind: "web"), to: "/libraries", request: request)
        }

        router.add(.GET, "/login") { request in
            if await context.setup.isNeeded { return .redirect("/setup") }
            return .html(loginPage(Strings(request.language), message: request.query["error"]))
        }

        router.add(.POST, "/login") { request in
            try checkOrigin(request)
            let form = request.form
            do {
                let user = try await context.signIn(name: form["name"] ?? "", password: form["password"] ?? "", from: request.remoteAddress)
                return signedIn(try context.issueToken(for: user, deviceName: browserName(request), kind: "web"), to: "/", request: request)
            } catch let error as HTTPError {
                return .html(loginPage(Strings(request.language), message: nil, error: error.message), status: error.status)
            }
        }

        router.add(.POST, "/logout") { request in
            try checkOrigin(request)
            if let caller = await context.caller(request), let device = caller.device { try context.store.removeDevice(id: device.id) }
            var response = Response.redirect("/login")
            response.headers.add(name: "Set-Cookie", value: "\(ServerContext.sessionCookie)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
            return response
        }

        // MARK: Libraries

        router.add(.GET, "/libraries") { request in
            let caller = try await adminPage(request, context)
            let strings = Strings(request.language)
            var page = WebPage(title: strings["libraries"], strings: strings, caller: caller)
            page.add("<h1>\(h(strings["libraries"]))</h1>")
            if let message = request.query["error"] { page.add("<p class=\"error\">\(h(strings[message]))</p>") }
            let libraries = context.store.libraries()
            if libraries.isEmpty { page.add("<p class=\"empty\">\(h(strings["noLibraries"]))</p>") }
            page.add("<div class=\"rows\">")
            for library in libraries {
                let state = library.lastError == nil ? "\(strings["lastScan"]) : \(strings.date(library.lastScanAt))" : strings["unreachable"]
                page.add("""
                    <div class="row"><div><strong>\(h(library.name))</strong><code>\(h(library.path))</code>
                    <span>\(h(strings.seriesCount(library.seriesCount))) · \(h(strings.bookCount(library.bookCount, kind: .book))) · \(h(state))</span></div>
                    <form method="post" action="/libraries/\(library.id)/scan"><button class="quiet">\(h(strings["scanNow"]))</button></form>
                    <form method="post" action="/libraries/\(library.id)/remove"><button class="quiet danger">\(h(strings["remove"]))</button></form></div>
                    """)
            }
            page.add("</div>")
            page.add("""
                <h2>\(h(strings["addLibrary"]))</h2>
                <form class="stack" method="post" action="/libraries">
                <label>\(h(strings["name"]))<input name="name" required placeholder="Mangas"></label>
                <label>\(h(strings["folder"]))<input name="path" required placeholder="/libraries/Mangas"></label>
                <p class="hint">\(h(strings["libraryHint"]))</p>
                <button>\(h(strings["add"]))</button></form>
                """)
            return .html(page.html)
        }

        router.add(.POST, "/libraries") { request in
            _ = try await adminAction(request, context)
            let form = request.form
            let name = (form["name"] ?? "").trimmingCharacters(in: .whitespaces)
            let path = URL(fileURLWithPath: (form["path"] ?? "").trimmingCharacters(in: .whitespaces)).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard !name.isEmpty else { return .redirect("/libraries?error=nameMissing") }
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .redirect("/libraries?error=folderMissing")
            }
            let id = try context.store.addLibrary(name: name, path: path)
            await context.scanner.enqueue(id)
            return .redirect("/libraries")
        }

        router.add(.POST, "/libraries/:id/scan") { request in
            _ = try await adminAction(request, context)
            if let id = request.parameter("id") { await context.scanner.enqueue(id) }
            return .redirect("/libraries")
        }

        router.add(.POST, "/libraries/:id/remove") { request in
            _ = try await adminAction(request, context)
            if let id = request.parameter("id") { try context.store.removeLibrary(id: id) }
            return .redirect("/libraries")
        }

        // MARK: Members

        router.add(.GET, "/members") { request in
            let caller = try await adminPage(request, context)
            let strings = Strings(request.language)
            let libraries = context.store.libraries()
            var page = WebPage(title: strings["members"], strings: strings, caller: caller)
            page.add("<h1>\(h(strings["members"]))</h1>")
            if let message = request.query["error"] { page.add("<p class=\"error\">\(h(strings[message]))</p>") }
            if request.query["saved"] != nil { page.add("<p class=\"ok\">\(h(strings["saved"]))</p>") }
            page.add("<div class=\"rows\">")
            let users = context.store.users()
            for user in users {
                let appOnly = context.store.credentials(name: user.name)?.1.isEmpty == true
                page.add("<div class=\"member\"><div class=\"who\"><strong>\(h(user.name))</strong> <span class=\"tag\">\(h(strings[user.isAdmin ? "admin" : "member"]))</span>\(appOnly ? " <span class=\"tag\">\(h(strings["appOnly"]))</span>" : "")</div>")
                page.add("<form method=\"post\" action=\"/members/\(user.id)/invite\" class=\"inline\"><button class=\"quiet\">\(h(strings["inviteDevice"]))</button></form>")
                if !user.isAdmin {
                    page.add("<form method=\"post\" action=\"/members/\(user.id)\" class=\"choices\">\(libraryChoices(libraries, all: user.allLibraries, chosen: user.libraryIDs, strings: strings))<button class=\"quiet\">\(h(strings["save"]))</button></form>")
                }
                page.add("""
                    <form method="post" action="/members/\(user.id)/password" class="inline"><input type="password" name="password" minlength="8" placeholder="\(h(strings["newPassword"]))" required><button class="quiet">\(h(strings["change"]))</button></form>
                    """)
                if !user.isAdmin {
                    page.add("<form method=\"post\" action=\"/members/\(user.id)/remove\" class=\"inline\"><button class=\"quiet danger\">\(h(strings["delete"]))</button></form>")
                }
                page.add("</div>")
            }
            page.add("</div>")
            let invitations = context.store.openInvitations()
            if !invitations.isEmpty {
                page.add("<h2>\(h(strings["openInvitations"]))</h2><div class=\"rows\">")
                for invitation in invitations {
                    let name = users.first { $0.id == invitation.userID }?.name ?? "?"
                    page.add("""
                        <div class="row"><div><strong>\(h(name))</strong><span>\(h(strings["expires"])) \(h(strings.date(invitation.expiresAt)))</span></div>
                        <form method="post" action="/invitations/\(invitation.id)/remove"><button class="quiet danger">\(h(strings["cancel"]))</button></form></div>
                        """)
                }
                page.add("</div>")
            }
            page.add("""
                <h2>\(h(strings["addMember"]))</h2>
                <form class="stack" method="post" action="/members">
                <label>\(h(strings["name"]))<input name="name" required autocomplete="off"></label>
                <fieldset class="choices">\(libraryChoices(libraries, all: false, chosen: [], strings: strings))</fieldset>
                <label>\(h(strings["passwordOptional"]))<input type="password" name="password" minlength="8" autocomplete="new-password"></label>
                <p class="hint">\(h(strings["passwordOptionalHint"]))</p>
                <button>\(h(strings["addAndInvite"]))</button></form>
                """)
            return .html(page.html)
        }

        // A member without a password reads with Cool Reader only: the invitation shown next signs their device in.
        router.add(.POST, "/members") { request in
            let caller = try await adminAction(request, context)
            let form = request.form
            let name = (form["name"] ?? "").trimmingCharacters(in: .whitespaces)
            let password = form["password"] ?? ""
            if name.isEmpty { return .redirect("/members?error=nameMissing") }
            if !password.isEmpty, let problem = problem(name: name, password: password, again: nil) { return .redirect("/members?error=\(problem)") }
            guard context.store.credentials(name: name) == nil else { return .redirect("/members?error=nameTaken") }
            let id = try context.store.createUser(name: name, passwordHash: password.isEmpty ? "" : Passwords.hash(password), isAdmin: false,
                                                  allLibraries: form["all"] != nil, libraryIDs: request.formValues("library").compactMap { Int($0) })
            guard let user = context.store.user(id: id) else { throw HTTPError.notFound }
            return try await InvitationRoutes.invitationPage(for: user, lifetime: 48 * 3600, caller: caller, request: request, context: context)
        }

        router.add(.POST, "/members/:id") { request in
            _ = try await adminAction(request, context)
            guard let id = request.parameter("id") else { throw HTTPError.notFound }
            try context.store.setLibraries(userID: id, all: request.form["all"] != nil, libraryIDs: request.formValues("library").compactMap { Int($0) })
            return .redirect("/members?saved=1")
        }

        router.add(.POST, "/members/:id/password") { request in
            _ = try await adminAction(request, context)
            guard let id = request.parameter("id") else { throw HTTPError.notFound }
            let password = request.form["password"] ?? ""
            guard password.count >= 8 else { return .redirect("/members?error=passwordTooShort") }
            try context.store.setPassword(userID: id, hash: Passwords.hash(password))
            return .redirect("/members?saved=1")
        }

        router.add(.POST, "/members/:id/remove") { request in
            _ = try await adminAction(request, context)
            if let id = request.parameter("id") { try context.store.removeUser(id: id) }
            return .redirect("/members")
        }

        // MARK: Devices

        router.add(.GET, "/devices") { request in
            let caller = try await adminPage(request, context)
            let strings = Strings(request.language)
            let users = context.store.users()
            var page = WebPage(title: strings["devices"], strings: strings, caller: caller)
            page.add("<h1>\(h(strings["devices"]))</h1>")
            if let message = request.query["error"] { page.add("<p class=\"error\">\(h(strings[message]))</p>") }
            if let paired = request.query["paired"] { page.add("<p class=\"ok\">\(h(paired)) ✓</p>") }
            let options = users.map { "<option value=\"\($0.id)\">\(h($0.name))</option>" }.joined()
            page.add("""
                <h2>\(h(strings["addMyDevice"]))</h2><p class="hint">\(h(strings["addMyDeviceIntro"]))</p>
                <form method="post" action="/devices/invite"><button>\(h(strings["showQRCode"]))</button></form>
                <h2>\(h(strings["pairDevice"]))</h2><p class="hint">\(h(strings["pairIntro"]))</p>
                <form class="inline wide" method="post" action="/devices/pair">
                <input name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="482 715" required class="code">
                <label>\(h(strings["for"])) <select name="user">\(options)</select></label><button>\(h(strings["approve"]))</button></form>
                """)
            let devices = context.store.devices()
            page.add("<h2>\(h(strings["devices"]))</h2>")
            if devices.isEmpty { page.add("<p class=\"empty\">\(h(strings["noDevices"]))</p>") }
            page.add("<div class=\"rows\">")
            for device in devices {
                let owner = users.first { $0.id == device.userID }?.name ?? "?"
                page.add("""
                    <div class="row"><div><strong>\(h(device.name))</strong><span>\(h(owner)) · \(h(device.kind)) · \(h(strings["lastSeen"])) \(h(strings.date(device.lastSeenAt)))</span></div>
                    <form method="post" action="/devices/\(device.id)/revoke"><button class="quiet danger">\(h(strings["revoke"]))</button></form></div>
                    """)
            }
            page.add("</div>")
            return .html(page.html)
        }

        router.add(.POST, "/devices/pair") { request in
            _ = try await adminAction(request, context)
            let form = request.form
            guard let id = form["user"].flatMap(Int.init), let user = context.store.user(id: id) else { throw HTTPError.notFound }
            guard let name = try await context.pairings.approve(code: form["code"] ?? "", user: user, store: context.store) else {
                return .redirect("/devices?error=unknownCode")
            }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return .redirect("/devices?paired=\(encoded)")
        }

        router.add(.POST, "/devices/:id/revoke") { request in
            _ = try await adminAction(request, context)
            if let id = request.parameter("id") { try context.store.removeDevice(id: id) }
            return .redirect("/devices")
        }
    }

    // MARK: - Helpers

    /// Forms only from this server's own pages: a page elsewhere can't make a signed-in admin's browser post here.
    static func checkOrigin(_ request: Request) throws {
        guard let origin = request.header("Origin"), origin != "null" else { return }
        guard let host = request.header("Host"), URL(string: origin)?.host.map({ host == $0 || host.hasPrefix($0 + ":") }) == true else {
            throw HTTPError(status: .forbidden, message: "This form comes from another site.")
        }
    }

    static func adminPage(_ request: Request, _ context: ServerContext) async throws -> Caller {
        guard let caller = await context.caller(request) else { throw HTTPError.unauthorized }
        guard caller.user.isAdmin else { throw HTTPError.forbidden }
        return caller
    }

    static func adminAction(_ request: Request, _ context: ServerContext) async throws -> Caller {
        try checkOrigin(request)
        return try await context.requireAdmin(request)
    }

    private static func problem(name: String, password: String, again: String?) -> String? {
        if name.isEmpty { return "nameMissing" }
        if password.count < 8 { return "passwordTooShort" }
        if let again, again != password { return "passwordsDiffer" }
        return nil
    }

    /// The session cookie; over HTTPS it never goes back over plain HTTP.
    private static func signedIn(_ token: String, to location: String, request: Request) -> Response {
        var response = Response.redirect(location)
        response.headers.add(name: "Set-Cookie", value: "\(ServerContext.sessionCookie)=\(token); Path=/; HttpOnly; SameSite=Strict; "
                                 + "Max-Age=2592000\(request.isSecure ? "; Secure" : "")")
        return response
    }

    private static func browserName(_ request: Request) -> String {
        let agent = request.header("User-Agent") ?? ""
        for (needle, name) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Macintosh", "Mac"), ("Windows", "Windows"), ("Linux", "Linux")]
            where agent.contains(needle) { return "Web · \(name)" }
        return "Web"
    }

    static func host(_ request: Request) -> String {
        "http://" + (request.header("Host") ?? "server:7272")
    }

    private static func libraryChoices(_ libraries: [LibraryRecord], all: Bool, chosen: [Int], strings: Strings) -> String {
        var html = "<label class=\"check\"><input type=\"checkbox\" name=\"all\"\(all ? " checked" : "")> \(h(strings["allLibraries"]))</label>"
        for library in libraries {
            html += "<label class=\"check\"><input type=\"checkbox\" name=\"library\" value=\"\(library.id)\"\(chosen.contains(library.id) ? " checked" : "")> \(h(library.name))</label>"
        }
        return html
    }

    private static func setupPage(_ strings: Strings, message: String?) -> String {
        WebPage.card(title: strings["setupTitle"], strings: strings, body: """
            <p class="hint">\(h(strings["setupIntro"]))</p>
            \(message.map { "<p class=\"error\">\(h(strings[$0]))</p>" } ?? "")
            <form class="stack" method="post" action="/setup">
            <label>\(h(strings["setupCode"]))<input name="code" inputmode="numeric" autocomplete="one-time-code" required class="code"></label>
            <label>\(h(strings["name"]))<input name="name" required autocomplete="username"></label>
            <label>\(h(strings["password"]))<input type="password" name="password" minlength="8" required autocomplete="new-password"></label>
            <label>\(h(strings["passwordAgain"]))<input type="password" name="again" minlength="8" required autocomplete="new-password"></label>
            <button>\(h(strings["createAdmin"]))</button></form>
            """)
    }

    private static func loginPage(_ strings: Strings, message: String?, error: String? = nil) -> String {
        WebPage.card(title: strings["signIn"], strings: strings, body: """
            \((error ?? message.map { strings[$0] }).map { "<p class=\"error\">\(h($0))</p>" } ?? "")
            <form class="stack" method="post" action="/login">
            <label>\(h(strings["name"]))<input name="name" required autocomplete="username"></label>
            <label>\(h(strings["password"]))<input type="password" name="password" required autocomplete="current-password"></label>
            <button>\(h(strings["signIn"]))</button></form>
            """)
    }
}

/// HTML escaping.
nonisolated func h(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// A page with the server's header: search and menu.
nonisolated struct WebPage {
    var title: String
    var strings: Strings
    var caller: Caller
    /// The menu entry this page belongs to.
    var section: String?
    /// What the search field shows.
    var search: String
    /// Seconds after which the page reloads itself, while something it shows is under way.
    var refresh: Int?
    private var body = ""

    init(title: String, strings: Strings, caller: Caller, section: String? = nil, search: String = "") {
        self.title = title
        self.strings = strings
        self.caller = caller
        self.section = section
        self.search = search
    }

    mutating func add(_ html: String) { body += html + "\n" }

    var html: String {
        var links = [("/", strings["home"])]
        if caller.user.isAdmin {
            links += [("/libraries", strings["libraries"]), ("/members", strings["members"]), ("/devices", strings["devices"]),
                      ("/server", strings["server"])]
        }
        let current = section ?? ""
        let menu = links.map { link in
            "<a href=\"\(link.0)\"\(current == link.0 ? " aria-current=\"page\"" : "")>\(h(link.1))</a>"
        }.joined()
        return Self.document(title: title, language: strings.language, refresh: refresh, body: """
            <header class="top"><a class="brand" href="/">Cool Reader <span>Server</span></a>
            <form class="search" method="get" action="/search" role="search"><input type="search" name="q" value="\(h(search))" \
            placeholder="\(h(strings["searchPlaceholder"]))" aria-label="\(h(strings["search"]))"></form>
            <nav>\(menu)<form method="post" action="/logout"><button class="link">\(h(strings["signOut"]))</button></form></nav></header>
            <main>\(body)</main>
            """)
    }

    static func card(title: String, strings: Strings, body: String) -> String {
        document(title: title, language: strings.language, body: """
            <main class="card"><p class="brand">Cool Reader <span>Server</span></p><h1>\(h(title))</h1>\(body)</main>
            """)
    }

    static func document(title: String, language: String, refresh: Int? = nil, body: String, bodyClass: String? = nil) -> String {
        """
        <!doctype html><html lang="\(language)"><head><meta charset="utf-8">\(refresh.map { "<meta http-equiv=\"refresh\" content=\"\($0)\">" } ?? "")
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="color-scheme" content="dark">
        <title>\(h(title))</title><link rel="stylesheet" href="/style.css?v=\(version(of: css))"></head><body\(bodyClass.map { " class=\"\($0)\"" } ?? "")>\(body)</body></html>
        """
    }

    /// A short hash of a file the pages load, put in its address: a new server's style and scripts replace the
    /// ones browsers keep for an hour.
    static func version(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Dark, like Plex: covers stand out and the reader stays in the dark.
    static let css = """
    :root { --bg: #111113; --surface: #1a1a1d; --raised: #24242a; --ink: #f2efea; --muted: #a39e97; --line: #2e2e33;
      --accent: #e8643f; --accent-ink: #1b0e09; --ok: #6fd093; --danger: #ff8a7d; color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-font-smoothing: antialiased; }
    a { color: inherit; }
    .top { position: sticky; top: 0; z-index: 10; display: flex; flex-wrap: wrap; gap: 10px 22px; align-items: center;
      padding: 12px max(16px, env(safe-area-inset-left)); background: rgb(17 17 19 / 0.88); border-bottom: 1px solid var(--line);
      backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); }
    .brand { font-weight: 700; text-decoration: none; letter-spacing: 0.01em; margin: 0; white-space: nowrap; }
    .brand span { color: var(--accent); }
    .search { flex: 1 1 180px; max-width: 360px; }
    .search input { width: 100%; padding: 7px 14px; border-radius: 999px; background: var(--raised); border-color: transparent; }
    nav { display: flex; flex-wrap: wrap; gap: 6px 18px; align-items: center; margin-left: auto; }
    nav a { text-decoration: none; color: var(--muted); }
    nav a:hover, nav a[aria-current] { color: var(--ink); }
    nav form { margin: 0; }
    main { max-width: 1320px; margin: 0 auto; padding: 24px max(16px, env(safe-area-inset-left)) 64px; }
    main.card { max-width: 420px; margin: 8vh auto; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 28px; }
    h1 { font-size: 28px; line-height: 1.15; margin: 8px 0 16px; text-wrap: balance; }
    h2 { font-size: 19px; margin: 32px 0 12px; }
    h1 small, h2 small { font-size: 14px; font-weight: 400; color: var(--muted); margin-left: 6px; }
    h2 a { text-decoration: none; }
    .row-section { margin-top: 28px; }
    .row-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
    .row-head h2 { margin: 0 0 12px; }
    .more { color: var(--muted); text-decoration: none; font-size: 14px; white-space: nowrap; }
    .more:hover { color: var(--ink); }
    .shelf { display: grid; grid-auto-flow: column; grid-auto-columns: 148px; gap: 16px; overflow-x: auto; padding: 4px 2px 12px;
      scroll-snap-type: x proximity; scrollbar-width: thin; }
    .shelf > * { scroll-snap-align: start; }
    .grid { display: grid; gap: 22px 16px; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); }
    .card { display: flex; flex-direction: column; gap: 4px; text-decoration: none; min-width: 0; }
    .card > a { display: flex; flex-direction: column; gap: 4px; text-decoration: none; }
    .art { position: relative; display: block; border-radius: 6px; overflow: hidden; background: var(--raised);
      box-shadow: 0 2px 10px rgb(0 0 0 / 0.45); transition: transform 0.15s ease, box-shadow 0.15s ease; }
    .card:hover .art, .card a:focus-visible .art { transform: translateY(-3px); box-shadow: 0 8px 22px rgb(0 0 0 / 0.55); }
    .art img { display: block; width: 100%; aspect-ratio: 2 / 3; object-fit: cover; }
    .card strong { font-size: 14px; line-height: 1.25; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .sub { font-size: 13px; color: var(--muted); }
    .badge { position: absolute; top: 6px; right: 6px; min-width: 24px; height: 24px; padding: 0 7px; border-radius: 999px; background: var(--accent);
      color: var(--accent-ink); font-size: 13px; font-weight: 700; display: grid; place-items: center; box-shadow: 0 1px 4px rgb(0 0 0 / 0.5); }
    .badge.done { background: rgb(17 17 19 / 0.82); color: var(--ok); }
    .art .bar { position: absolute; left: 0; right: 0; bottom: 0; height: 4px; background: rgb(0 0 0 / 0.6); }
    .art .bar span { display: block; height: 100%; background: var(--accent); }
    .tools { display: flex; flex-wrap: wrap; gap: 2px 12px; font-size: 13px; }
    .tools a, .tools button { color: var(--muted); text-decoration: none; font-size: 13px; }
    .tools a:hover, .tools button:hover { color: var(--ink); }
    .volumes { grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); }
    .hero { position: relative; margin: -24px calc(-1 * max(16px, env(safe-area-inset-left))) 8px; padding: 48px max(16px, env(safe-area-inset-left)) 28px;
      overflow: hidden; isolation: isolate; }
    .backdrop { position: absolute; inset: 0; z-index: -2; background-size: cover; background-position: center 30%;
      filter: blur(28px) brightness(0.42) saturate(1.2); transform: scale(1.15); }
    .hero.banner .backdrop { filter: brightness(0.45); transform: none; }
    .hero::after { content: ""; position: absolute; inset: 0; z-index: -1; background: linear-gradient(to bottom, rgb(17 17 19 / 0.1), var(--bg) 96%); }
    .hero-body { display: grid; grid-template-columns: minmax(130px, 230px) 1fr; gap: 28px; align-items: end; max-width: 1320px; margin: 0 auto; }
    .poster { width: 100%; border-radius: 8px; box-shadow: 0 10px 30px rgb(0 0 0 / 0.6); background: var(--raised); }
    .info h1 { font-size: clamp(28px, 4vw, 44px); margin: 0 0 8px; }
    .facts { color: var(--muted); margin: 0 0 10px; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 14px; }
    .chip { font-size: 13px; border: 1px solid rgb(255 255 255 / 0.18); border-radius: 999px; padding: 2px 10px; color: var(--ink); }
    .actions { margin: 0 0 14px; }
    .button.play { font-size: 17px; padding: 10px 22px; }
    .summary { max-width: 72ch; white-space: pre-line; margin: 0; color: #ddd8d1; }
    @media (max-width: 620px) { .hero-body { grid-template-columns: 1fr; } .poster { max-width: 170px; } .top { position: static; } }
    .heading { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 8px 20px; }
    .sort { display: flex; gap: 14px; margin: 0; }
    .sort a { color: var(--muted); text-decoration: none; }
    .sort a[aria-current] { color: var(--ink); font-weight: 600; }
    .rows { display: flex; flex-direction: column; border-top: 1px solid var(--line); }
    .row, .member { display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center; padding: 14px 0; border-bottom: 1px solid var(--line); }
    .row > div { flex: 1 1 260px; display: flex; flex-direction: column; min-width: 0; }
    .row span { font-size: 13px; color: var(--muted); }
    .row code { font-size: 13px; overflow-wrap: anywhere; }
    .member .who { flex: 1 1 100%; }
    .tag { font-size: 12px; color: var(--muted); border: 1px solid var(--line); border-radius: 999px; padding: 1px 8px; margin-left: 4px; }
    form { margin: 0; }
    .stack { display: flex; flex-direction: column; gap: 14px; max-width: 460px; }
    .inline { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .wide { margin-bottom: 8px; }
    .choices { display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: center; border: 0; padding: 0; margin: 0; }
    label { display: flex; flex-direction: column; gap: 6px; font-size: 14px; color: var(--muted); }
    label.check { flex-direction: row; align-items: center; gap: 6px; color: var(--ink); }
    input, select { font: inherit; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 9px 11px; }
    input.code { font-variant-numeric: tabular-nums; letter-spacing: 0.2em; max-width: 12ch; }
    input:focus, select:focus, button:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    button, .button { font: inherit; font-weight: 600; border: 0; border-radius: 8px; padding: 9px 16px; background: var(--accent);
      color: var(--accent-ink); cursor: pointer; text-decoration: none; display: inline-block; }
    button.quiet, .button.quiet { background: transparent; color: var(--ink); border: 1px solid var(--line); font-weight: 500; }
    button.danger { color: var(--danger); }
    button.link { background: none; color: var(--muted); padding: 0; font-weight: 400; }
    .status { color: var(--muted); min-height: 1.5em; margin: 0 0 8px; }
    .empty, .hint { color: var(--muted); }
    .hint { font-size: 14px; }
    .error { color: var(--danger); }
    .ok { color: var(--ok); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
    .invite { display: flex; flex-wrap: wrap; gap: 20px 32px; align-items: center; margin: 8px 0 20px; }
    .qr svg { width: 240px; height: auto; display: block; border-radius: 8px; }
    .steps { margin: 0; padding-left: 20px; display: flex; flex-direction: column; gap: 8px; max-width: 46ch; }
    .fingerprint { overflow-wrap: anywhere; font-size: 13px; }
    #invitation-link { width: 100%; max-width: 640px; font-size: 13px; margin-bottom: 4px; }
    body.reader-page { background: #000; overflow: hidden; }
    #reader { position: fixed; inset: 0; display: grid; place-items: center; background: #000; user-select: none; -webkit-user-select: none; }
    #page { display: block; max-width: 100vw; max-height: 100vh; max-height: 100dvh; object-fit: contain; }
    .zones { position: fixed; inset: 0; display: grid; grid-template-columns: 1fr 1fr 1fr; }
    .zone { background: transparent; border: 0; border-radius: 0; padding: 0; margin: 0; cursor: pointer; -webkit-tap-highlight-color: transparent; }
    .zone:focus-visible { outline: none; }
    #reader .bar { position: fixed; left: 0; right: 0; z-index: 2; display: flex; align-items: center; gap: 16px; color: #eee;
      padding: max(10px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) 10px max(16px, env(safe-area-inset-left));
      background: rgb(0 0 0 / 0.74); transition: opacity 0.2s ease; }
    #reader .bar.top { top: 0; }
    #reader .bar.bottom { bottom: 0; padding-bottom: max(14px, env(safe-area-inset-bottom)); }
    #reader:not(.chrome) .bar { opacity: 0; pointer-events: none; }
    #reader .back { text-decoration: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 40%; }
    #reader .title { flex: 1; text-align: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #bbb; }
    #counter { font-variant-numeric: tabular-nums; color: #bbb; }
    #scrub { width: 100%; accent-color: var(--accent); background: transparent; border: 0; padding: 0; }
    #end { position: fixed; inset: 0; z-index: 3; display: grid; place-content: center; justify-items: center; gap: 8px; text-align: center;
      background: rgb(0 0 0 / 0.86); font-size: 18px; }
    #end[hidden] { display: none; }
    @media (prefers-reduced-motion: reduce) { .art, #reader .bar { transition: none; } }
    """
}
