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
            var page = WebPage(title: strings["libraries"], strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), section: "/libraries")
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
            var page = WebPage(title: strings["members"], strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), section: "/members")
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
            var page = WebPage(title: strings["devices"], strings: strings, caller: caller, libraries: context.store.visibleLibraries(for: caller.user), section: "/devices")
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

/// A page of the site, in the spirit of Plex: a sidebar with the home page, the libraries the member reads and the
/// admin's pages, the search above, and the page itself.
nonisolated struct WebPage {
    var title: String
    var strings: Strings
    var caller: Caller
    /// The libraries in the sidebar: those the member may read.
    var libraries: [LibraryRecord]
    /// The sidebar entry this page belongs to.
    var section: String?
    /// What the search field shows.
    var search: String
    /// Seconds after which the page reloads itself, while something it shows is under way.
    var refresh: Int?
    private var body = ""

    init(title: String, strings: Strings, caller: Caller, libraries: [LibraryRecord], section: String? = nil, search: String = "") {
        self.title = title
        self.strings = strings
        self.caller = caller
        self.libraries = libraries
        self.section = section
        self.search = search
    }

    mutating func add(_ html: String) { body += html + "\n" }

    var html: String {
        let current = section ?? ""
        func link(_ href: String, _ label: String, icon: String, count: Int? = nil) -> String {
            "<a href=\"\(href)\"\(current == href ? " aria-current=\"page\"" : "")>\(icon)<span>\(h(label))</span>\(count.map { "<small>\($0)</small>" } ?? "")</a>"
        }
        var side = link("/", strings["home"], icon: Icon.home)
        if !libraries.isEmpty {
            side += "<p class=\"side-title\">\(h(strings["libraries"]))</p>"
            side += libraries.map { link("/library/\($0.id)", $0.name, icon: Icon.library(named: $0.name), count: $0.seriesCount) }.joined()
        }
        if caller.user.isAdmin {
            side += "<p class=\"side-title\">\(h(strings["administration"]))</p>"
            side += link("/libraries", strings["manageLibraries"], icon: Icon.folder) + link("/members", strings["members"], icon: Icon.members)
                + link("/devices", strings["devices"], icon: Icon.devices) + link("/server", strings["server"], icon: Icon.server)
        }
        let initial = caller.user.name.first.map { String($0).uppercased() } ?? "?"
        return Self.document(title: title, language: strings.language, refresh: refresh, body: """
            <div class="shell"><aside class="sidebar"><a class="brand" href="/">\(Icon.mark)<span>Cool Reader <em>Server</em></span></a>
            <nav class="side-nav">\(side)</nav>
            <div class="side-foot"><span class="avatar" aria-hidden="true">\(h(initial))</span><span class="who">\(h(caller.user.name))</span>\
            <form method="post" action="/logout"><button class="icon-button" title="\(h(strings["signOut"]))" aria-label="\(h(strings["signOut"]))">\(Icon.signOut)</button></form></div></aside>
            <div class="content"><header class="topbar"><form class="search" method="get" action="/search" role="search">\(Icon.search)\
            <input type="search" name="q" value="\(h(search))" placeholder="\(h(strings["searchPlaceholder"]))" aria-label="\(h(strings["search"]))"></form></header>
            <main>\(body)</main></div></div>
            """)
    }

    static func card(title: String, strings: Strings, body: String) -> String {
        document(title: title, language: strings.language, body: """
            <main class="card"><p class="brand">\(Icon.mark)<span>Cool Reader <em>Server</em></span></p><h1>\(h(title))</h1>\(body)</main>
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

    /// Dark, like Plex: covers and backdrops stand out, and the reader stays in the dark.
    static let css = """
    :root { --bg: #0e0e10; --surface: #19191d; --raised: #24242a; --ink: #f4f1ec; --muted: #a8a29b; --faint: #6f6a64; --line: #29292f;
      --accent: #e8643f; --accent-2: #f2a14a; --accent-ink: #1b0e09; --ok: #6fd093; --danger: #ff8a7d; --side: 252px;
      --pad: clamp(16px, 3vw, 40px); --topbar: 68px; color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; color: var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(1100px 520px at 78% -12%, rgb(232 100 63 / 0.13), transparent 62%), var(--bg); background-attachment: fixed;
      -webkit-font-smoothing: antialiased; }
    a { color: inherit; }
    .icon { width: 20px; height: 20px; flex: none; }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: 0.01em; text-decoration: none; margin: 0; white-space: nowrap; }
    .brand em { font-style: normal; color: var(--accent); }
    .mark { width: 30px; height: 30px; flex: none; }
    .mark-tile { fill: var(--accent); }
    .mark-book { fill: none; stroke: var(--accent-ink); stroke-width: 1.9; stroke-linejoin: round; }
    .shell { display: grid; grid-template-columns: var(--side) minmax(0, 1fr); min-height: 100vh; }
    .sidebar { position: sticky; top: 0; height: 100vh; height: 100dvh; display: flex; flex-direction: column; gap: 14px; overflow-y: auto;
      padding: 20px 14px 14px max(14px, env(safe-area-inset-left)); background: rgb(19 19 22 / 0.78); border-right: 1px solid var(--line);
      backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); }
    .sidebar .brand { padding: 2px 8px 10px; font-size: 17px; }
    .side-nav { display: flex; flex-direction: column; gap: 2px; }
    .side-title { margin: 18px 10px 6px; font-size: 11px; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
    .side-nav a { display: flex; align-items: center; gap: 12px; padding: 9px 10px; border-radius: 10px; color: var(--muted); text-decoration: none;
      font-size: 15px; transition: background 0.15s ease, color 0.15s ease; }
    .side-nav a span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .side-nav a small { font-size: 12px; color: var(--faint); font-variant-numeric: tabular-nums; }
    .side-nav a:hover { background: rgb(255 255 255 / 0.05); color: var(--ink); }
    .side-nav a[aria-current] { color: var(--ink); background: linear-gradient(90deg, rgb(232 100 63 / 0.24), rgb(232 100 63 / 0.05));
      box-shadow: inset 3px 0 0 var(--accent); }
    .side-nav a[aria-current] .icon { color: var(--accent); }
    .side-foot { margin-top: auto; display: flex; align-items: center; gap: 10px; padding: 12px 8px 4px; border-top: 1px solid var(--line); }
    .avatar { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; flex: none; font-size: 13px; font-weight: 700;
      color: var(--accent-ink); background: linear-gradient(135deg, var(--accent-2), var(--accent)); }
    .who { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
    button.icon-button { display: grid; place-items: center; padding: 6px; border-radius: 8px; background: transparent; color: var(--muted); }
    button.icon-button:hover { color: var(--ink); background: rgb(255 255 255 / 0.07); }
    .content { min-width: 0; }
    .topbar { position: sticky; top: 0; z-index: 10; height: var(--topbar); display: flex; align-items: center; gap: 16px; padding: 0 var(--pad);
      background: rgb(14 14 16 / 0.55); backdrop-filter: blur(16px) saturate(1.3); -webkit-backdrop-filter: blur(16px) saturate(1.3); }
    .search { position: relative; flex: 1 1 auto; max-width: 460px; }
    .search .icon { position: absolute; left: 13px; top: 50%; width: 18px; height: 18px; transform: translateY(-50%); color: var(--faint); pointer-events: none; }
    .search input { width: 100%; padding: 9px 16px 9px 40px; border-radius: 999px; background: rgb(255 255 255 / 0.08); border: 1px solid rgb(255 255 255 / 0.07); }
    .search input:focus { background: rgb(255 255 255 / 0.12); }
    main { max-width: 1680px; padding: 8px var(--pad) 72px; }
    main.card { max-width: 420px; margin: 8vh auto; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 28px; }
    main.card .brand { margin-bottom: 4px; }
    h1 { font-size: 28px; line-height: 1.15; margin: 8px 0 16px; text-wrap: balance; }
    h2 { font-size: 20px; margin: 32px 0 12px; letter-spacing: -0.01em; }
    h1 small, h2 small { font-size: 14px; font-weight: 400; color: var(--muted); margin-left: 6px; letter-spacing: 0; }
    h2 a { text-decoration: none; }
    .row-section { margin-top: 34px; }
    .row-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
    .row-head h2 { margin: 0 0 14px; }
    .row-head h2 a { display: inline-flex; align-items: center; gap: 10px; }
    .row-head h2 a:hover { color: var(--accent); }
    .row-head h2 .icon { width: 22px; height: 22px; color: var(--accent); }
    .more { color: var(--muted); text-decoration: none; font-size: 14px; white-space: nowrap; }
    .more:hover { color: var(--ink); }
    .shelf { display: grid; grid-auto-flow: column; grid-auto-columns: 152px; gap: 18px; overflow-x: auto; padding: 6px 4px 14px;
      margin: 0 -4px; scroll-snap-type: x proximity; scrollbar-width: thin; scrollbar-color: var(--raised) transparent; }
    .shelf > * { scroll-snap-align: start; }
    .grid { display: grid; gap: 26px 18px; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); }
    .card { display: flex; flex-direction: column; gap: 5px; text-decoration: none; min-width: 0; }
    .card > a { display: flex; flex-direction: column; gap: 5px; text-decoration: none; }
    .art { position: relative; display: block; border-radius: 10px; overflow: hidden; background: var(--raised);
      box-shadow: 0 4px 14px rgb(0 0 0 / 0.45); transition: transform 0.2s ease, box-shadow 0.2s ease; }
    .card:hover .art, .card a:focus-visible .art { transform: translateY(-4px);
      box-shadow: 0 0 0 2px rgb(232 100 63 / 0.85), 0 14px 30px rgb(0 0 0 / 0.55); }
    .art img { display: block; width: 100%; aspect-ratio: 2 / 3; object-fit: cover; transition: transform 0.35s ease; }
    .card:hover .art img { transform: scale(1.04); }
    .card strong { font-size: 14px; line-height: 1.25; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .sub { font-size: 13px; color: var(--muted); }
    .badge { position: absolute; top: 7px; right: 7px; min-width: 24px; height: 24px; padding: 0 7px; border-radius: 999px; background: var(--accent);
      color: var(--accent-ink); font-size: 13px; font-weight: 700; display: grid; place-items: center; box-shadow: 0 1px 4px rgb(0 0 0 / 0.5); }
    .badge.done { background: rgb(14 14 16 / 0.82); color: var(--ok); }
    .art .bar { position: absolute; left: 0; right: 0; bottom: 0; height: 4px; background: rgb(0 0 0 / 0.6); }
    .art .bar span { display: block; height: 100%; background: linear-gradient(90deg, var(--accent), var(--accent-2)); }
    .tools { display: flex; flex-wrap: wrap; gap: 2px 12px; font-size: 13px; }
    .tools a, .tools button { color: var(--muted); text-decoration: none; font-size: 13px; }
    .tools a:hover, .tools button:hover { color: var(--ink); }
    .volumes { grid-template-columns: repeat(auto-fill, minmax(136px, 1fr)); }
    .hero { position: relative; margin: -8px calc(-1 * var(--pad)) 8px; padding: 48px var(--pad) 30px; overflow: hidden; isolation: isolate; }
    .backdrop { position: absolute; inset: 0; z-index: -2; background-size: cover; background-position: center 30%;
      filter: blur(30px) brightness(0.55) saturate(1.45); transform: scale(1.18); }
    .hero.banner .backdrop { filter: brightness(0.55) saturate(1.1); transform: none; }
    .hero::after { content: ""; position: absolute; inset: 0; z-index: -1;
      background: linear-gradient(90deg, rgb(14 14 16 / 0.82), rgb(14 14 16 / 0.25) 55%, rgb(14 14 16 / 0)),
                  linear-gradient(to bottom, rgb(14 14 16 / 0) 35%, var(--bg)); }
    .hero.covers .mosaic { top: -40px; left: -4%; width: 125%; flex-wrap: wrap; opacity: 0.5; }
    .hero.covers .mosaic img { width: 138px; }
    .hero.covers::after { background: linear-gradient(90deg, rgb(14 14 16 / 0.92), rgb(14 14 16 / 0.6) 55%, rgb(14 14 16 / 0.35)),
                                      linear-gradient(to bottom, rgb(14 14 16 / 0) 30%, var(--bg)); }
    .hero-body { position: relative; display: grid; grid-template-columns: minmax(130px, 230px) 1fr; gap: 30px; align-items: end; max-width: 1400px; }
    .poster { width: 100%; border-radius: 12px; box-shadow: 0 16px 40px rgb(0 0 0 / 0.6); background: var(--raised); }
    .overline { margin: 0 0 8px; font-size: 12px; font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent-2); }
    .info h1 { font-size: clamp(30px, 4.4vw, 54px); line-height: 1.04; letter-spacing: -0.02em; margin: 0 0 10px; }
    .info h1 a { text-decoration: none; }
    .facts { color: var(--muted); margin: 0 0 12px; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 16px; }
    .chip { font-size: 13px; border: 1px solid rgb(255 255 255 / 0.18); border-radius: 999px; padding: 2px 11px; background: rgb(255 255 255 / 0.05); }
    .actions { display: flex; flex-wrap: wrap; gap: 10px; margin: 0 0 16px; }
    .button.play { display: inline-flex; align-items: center; gap: 8px; font-size: 17px; padding: 11px 22px; border-radius: 999px;
      box-shadow: 0 8px 24px rgb(232 100 63 / 0.35); }
    .button.glass { display: inline-flex; align-items: center; font-size: 17px; padding: 11px 22px; border-radius: 999px; color: var(--ink);
      background: rgb(255 255 255 / 0.12); border: 1px solid rgb(255 255 255 / 0.16); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); }
    .button.glass:hover { background: rgb(255 255 255 / 0.2); }
    .summary { max-width: 72ch; white-space: pre-line; margin: 0; color: #e2ddd6; }
    .credit { margin: 8px 0 0; font-size: 12px; color: var(--faint); }
    .credit a { color: var(--muted); }
    .hero.spotlight { display: flex; align-items: flex-end; min-height: min(64vh, 580px); border-radius: 0 0 26px 26px; }
    .spotlight .hero-body { width: 100%; grid-template-columns: minmax(120px, 210px) 1fr; }
    .spotlight .summary { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; white-space: normal; }
    .tiles { display: grid; gap: 18px; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); }
    .tile { position: relative; isolation: isolate; overflow: hidden; display: flex; flex-direction: column; justify-content: flex-end; min-height: 238px;
      padding: 16px 18px; border-radius: 18px; text-decoration: none; background: var(--surface); border: 1px solid rgb(255 255 255 / 0.07);
      box-shadow: 0 10px 30px rgb(0 0 0 / 0.35); transition: transform 0.2s ease, box-shadow 0.2s ease, border-color 0.2s ease; }
    .tile:hover, .tile:focus-visible { transform: translateY(-4px); border-color: rgb(232 100 63 / 0.55); box-shadow: 0 18px 42px rgb(0 0 0 / 0.5); }
    .tile-backdrop { position: absolute; inset: 0; z-index: -2; background-size: cover; background-position: center;
      filter: blur(26px) saturate(1.5) brightness(0.6); transform: scale(1.35); }
    .tile::after { content: ""; position: absolute; inset: 0; z-index: -1; background: linear-gradient(to top, rgb(14 14 16 / 0.96) 18%, rgb(14 14 16 / 0.15) 75%); }
    .tile-art { position: absolute; top: 18px; left: 50%; width: 0; height: 150px; }
    .tile-art img { position: absolute; top: 0; width: 96px; aspect-ratio: 2 / 3; object-fit: cover; border-radius: 8px; background: var(--raised);
      box-shadow: 0 10px 24px rgb(0 0 0 / 0.6); transition: transform 0.3s ease; }
    .tile-art img:nth-child(1) { z-index: 3; transform: translateX(-50%); }
    .tile-art img:nth-child(2) { z-index: 2; transform: translateX(-118%) rotate(-9deg) scale(0.88); }
    .tile-art img:nth-child(3) { z-index: 1; transform: translateX(18%) rotate(9deg) scale(0.88); }
    .tile:hover .tile-art img:nth-child(1) { transform: translateX(-50%) translateY(-4px); }
    .tile:hover .tile-art img:nth-child(2) { transform: translateX(-130%) rotate(-12deg) scale(0.88); }
    .tile:hover .tile-art img:nth-child(3) { transform: translateX(30%) rotate(12deg) scale(0.88); }
    .tile-art img:first-child:nth-last-child(2) { transform: translateX(-28%) rotate(6deg); }
    .tile-art img:nth-child(2):last-child { transform: translateX(-78%) rotate(-7deg) scale(0.92); }
    .tile:hover .tile-art img:first-child:nth-last-child(2) { transform: translateX(-20%) rotate(9deg); }
    .tile:hover .tile-art img:nth-child(2):last-child { transform: translateX(-88%) rotate(-10deg) scale(0.92); }
    .tile-empty { position: absolute; top: 34px; left: 50%; transform: translateX(-50%); color: var(--faint); }
    .tile-empty .icon { width: 72px; height: 72px; }
    .tile-text { display: grid; grid-template-columns: auto 1fr; column-gap: 12px; align-items: center; }
    .tile-text .icon { grid-row: span 2; width: 28px; height: 28px; color: var(--accent); }
    .tile-text strong { font-size: 19px; line-height: 1.2; }
    .library-head { position: relative; isolation: isolate; overflow: hidden; display: flex; flex-wrap: wrap; align-items: flex-end;
      justify-content: space-between; gap: 16px 24px; margin: -8px calc(-1 * var(--pad)) 26px; padding: 56px var(--pad) 26px; }
    .mosaic { position: absolute; top: -30px; left: -6%; z-index: -2; display: flex; gap: 14px; transform: rotate(-5deg); opacity: 0.42;
      filter: saturate(1.3); }
    .mosaic img { flex: none; width: 150px; aspect-ratio: 2 / 3; object-fit: cover; border-radius: 10px; background: var(--raised); }
    .library-head::after { content: ""; position: absolute; inset: 0; z-index: -1;
      background: linear-gradient(90deg, rgb(14 14 16 / 0.88), rgb(14 14 16 / 0.35) 65%, rgb(14 14 16 / 0.15)),
                  linear-gradient(to bottom, rgb(14 14 16 / 0) 30%, var(--bg)); }
    .library-title { display: flex; align-items: center; gap: 16px; }
    .library-title > .icon { width: 30px; height: 30px; padding: 13px; box-sizing: content-box; border-radius: 16px; color: var(--accent);
      background: rgb(232 100 63 / 0.16); border: 1px solid rgb(232 100 63 / 0.3); }
    .library-title h1 { font-size: clamp(30px, 4vw, 46px); letter-spacing: -0.02em; margin: 0; }
    .library-title .facts { margin: 2px 0 0; }
    .heading { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 8px 20px; }
    .sort { display: flex; gap: 8px; margin: 0; }
    .sort a { padding: 6px 14px; border-radius: 999px; color: var(--muted); text-decoration: none; font-size: 14px; background: rgb(255 255 255 / 0.07); }
    .sort a:hover { color: var(--ink); }
    .sort a[aria-current] { color: var(--bg); background: var(--ink); font-weight: 600; }
    .filters { display: flex; flex-direction: column; gap: 10px; margin: -6px 0 24px; }
    .sort.genres { flex-wrap: wrap; }
    .sort.genres a { font-size: 13px; padding: 4px 12px; }
    @media (min-width: 861px) {
      .hero, .library-head { margin-top: calc(-8px - var(--topbar)); }
      .hero { padding-top: calc(var(--topbar) + 56px); }
      .library-head { padding-top: calc(var(--topbar) + 48px); }
    }
    @media (max-width: 860px) {
      .shell { display: block; }
      .sidebar { position: sticky; top: 0; z-index: 30; height: auto; flex-direction: row; align-items: center; gap: 10px; overflow: visible;
        padding: 10px max(12px, env(safe-area-inset-right)) 10px max(12px, env(safe-area-inset-left)); border-right: 0; border-bottom: 1px solid var(--line); }
      .sidebar .brand { padding: 0; }
      .sidebar .brand span, .side-title, .side-nav a small, .side-foot .who, .side-foot .avatar { display: none; }
      .side-nav { flex: 1; min-width: 0; flex-direction: row; gap: 6px; overflow-x: auto; scrollbar-width: none; }
      .side-nav::-webkit-scrollbar { display: none; }
      .side-nav a { flex: none; gap: 8px; padding: 7px 13px; border-radius: 999px; font-size: 14px; background: rgb(255 255 255 / 0.07); }
      .side-nav a .icon { width: 18px; height: 18px; }
      .side-nav a[aria-current] { color: var(--accent-ink); background: var(--accent); box-shadow: none; }
      .side-nav a[aria-current] .icon { color: inherit; }
      .side-foot { margin: 0; padding: 0; border: 0; }
      .topbar { position: static; height: auto; padding: 12px var(--pad) 4px; background: none; backdrop-filter: none; -webkit-backdrop-filter: none; }
      .search { max-width: none; }
    }
    @media (max-width: 620px) {
      .hero-body, .spotlight .hero-body { grid-template-columns: 1fr; gap: 18px; }
      .poster { max-width: 150px; }
      .hero.spotlight { min-height: 0; }
      .spotlight .poster { max-width: 120px; }
      .shelf { grid-auto-columns: 128px; gap: 14px; }
      .grid { grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 20px 14px; }
      .tiles { grid-template-columns: 1fr; }
    }
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
    textarea { font: inherit; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 9px 11px;
      resize: vertical; }
    .admin-tools { display: flex; flex-wrap: wrap; gap: 6px 18px; margin: -4px 0 4px; font-size: 14px; }
    .admin-tools a, .back a { color: var(--muted); text-decoration: none; }
    .admin-tools a:hover, .back a:hover { color: var(--ink); }
    .back { margin: 4px 0 0; font-size: 14px; }
    .candidates { display: flex; flex-direction: column; gap: 10px; margin: 8px 0 12px; }
    .candidate { display: grid; grid-template-columns: 64px 1fr auto; gap: 14px; align-items: center; padding: 10px 12px; border-radius: 12px;
      background: var(--surface); border: 1px solid var(--line); }
    .candidate.current { border-color: rgb(232 100 63 / 0.7); }
    .candidate .art { width: 64px; }
    .candidate .art img { aspect-ratio: 2 / 3; }
    .candidate .what { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
    .candidate .excerpt { font-size: 13px; color: var(--muted); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .no-cover { display: grid; place-items: center; aspect-ratio: 2 / 3; color: var(--faint); }
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
    @media (prefers-reduced-motion: reduce) { .art, .art img, .tile, .tile-art img, .side-nav a, #reader .bar { transition: none; } }
    """
}
