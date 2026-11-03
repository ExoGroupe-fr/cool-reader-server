import Foundation
import NIOHTTP1

/// Invitations in the web admin: a QR code and a link that sign one device in as a member, and the server's page
/// (its name, addresses and certificate).
nonisolated enum InvitationRoutes {
    static let appStoreLink = "https://apps.apple.com/app/cool-reader/id6829489019"

    static func add(to router: inout Router, context: ServerContext) {
        router.add(.GET, "/admin.js") { _ in
            var response = Response(contentType: "text/javascript; charset=utf-8", data: Data(script.utf8))
            response.headers.add(name: "Cache-Control", value: "public, max-age=3600")
            return response
        }

        router.add(.POST, "/members/:id/invite") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            guard let id = request.parameter("id"), let user = context.store.user(id: id) else { throw HTTPError.notFound }
            return try await invitationPage(for: user, lifetime: 48 * 3600, caller: caller, request: request, context: context)
        }

        // An admin's own iPhone or iPad: a code to scan right away, short-lived.
        router.add(.POST, "/devices/invite") { request in
            let caller = try await AdminRoutes.adminAction(request, context)
            return try await invitationPage(for: caller.user, lifetime: 30 * 60, caller: caller, request: request, context: context)
        }

        router.add(.POST, "/invitations/:id/remove") { request in
            _ = try await AdminRoutes.adminAction(request, context)
            if let id = request.parameter("id") { try context.store.removeInvitation(id: id) }
            return .redirect("/members")
        }

        router.add(.GET, "/server") { request in
            let caller = try await AdminRoutes.adminPage(request, context)
            let strings = Strings(request.language)
            var page = WebPage(title: strings["server"], strings: strings, caller: caller)
            page.add("<h1>\(h(strings["server"]))</h1>")
            if request.query["saved"] != nil { page.add("<p class=\"ok\">\(h(strings["saved"]))</p>") }
            page.add("""
                <form class="stack" method="post" action="/server">
                <label>\(h(strings["serverName"]))<input name="name" value="\(h(context.serverName))" maxlength="60" required></label>
                <p class="hint">\(h(strings["serverNameHint"]))</p>
                <button>\(h(strings["save"]))</button></form>
                """)
            if let message = request.query["error"] { page.add("<p class=\"error\">\(h(strings[message]))</p>") }
            let addresses = context.addresses(requestHost: request.header("Host"), local: NetworkInterfaces.localAddresses(), public: [])
            page.add("<h2>\(h(strings["homeAddresses"]))</h2>")
            page.add(addresses.isEmpty ? "<p class=\"empty\">\(h(strings["noAddress"]))</p>"
                                       : "<p>" + addresses.map { "<code>\(h($0))</code>" }.joined(separator: " · ") + "</p>")
            let settings = context.remoteSettings
            let status = await context.remoteAccess.status
            if status.state == .working { page.refresh = 3 }
            let tone = status.state == .open || status.state == .manual ? "ok" : status.state == .failed ? "error" : "status"
            page.add("""
                <h2 id="remote">\(h(strings["remoteAccess"]))</h2><p class="hint">\(h(strings["remoteIntro"]))</p>
                <p class="\(tone)">\(h(strings.remoteStatus(status, port: context.config.port)))</p>
                \(status.detail.map { "<p class=\"hint\"><code>\(h($0))</code></p>" } ?? "")
                <form class="stack" method="post" action="/server/remote">
                <label class="check"><input type="checkbox" name="enabled"\(settings.isEnabled ? " checked" : "")> \(h(strings["remoteEnable"]))</label>
                <label>\(h(strings["remotePort"]))<input name="port" inputmode="numeric" value="\(settings.externalPort.map(String.init) ?? "")" placeholder="\(context.config.port)"></label>
                <label>\(h(strings["remoteHost"]))<input name="host" value="\(h(settings.publicHost ?? ""))" placeholder="books.example.org" autocomplete="off"></label>
                <label>\(h(strings["duckDNSDomain"]))<input name="duckdns" value="\(h(settings.duckDNSDomain ?? ""))" placeholder="myserver" autocomplete="off"></label>
                <label>\(h(strings["duckDNSToken"]))<input name="token" type="password" autocomplete="off" placeholder="\(settings.duckDNSToken == nil ? "" : "••••••••")"></label>
                \(settings.duckDNSToken == nil ? "" : "<p class=\"hint\">\(h(strings["duckDNSTokenKept"]))</p>")
                <p class="hint">\(h(strings["remoteInvitationsHint"]))</p>
                <button>\(h(strings["save"]))</button></form>
                """)
            page.add("""
                <h2>\(h(strings["certificate"]))</h2>
                <p class="hint">\(h(strings["certificateHint"]))</p>
                <p><code class="fingerprint">\(h(grouped(context.certificate.fingerprint)))</code></p>
                <p class="hint">Cool Reader Server \(h(ServerContext.version))</p>
                """)
            return .html(page.html)
        }

        router.add(.POST, "/server") { request in
            _ = try await AdminRoutes.adminAction(request, context)
            let name = (request.form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                try context.store.setSetting("server_name", String(name.prefix(60)))
                await context.advertising.rename(context.serverName)
            }
            return .redirect("/server?saved=1")
        }

        router.add(.POST, "/server/remote") { request in
            _ = try await AdminRoutes.adminAction(request, context)
            let form = request.form
            func field(_ name: String) -> String? {
                let value = (form[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            var settings = context.remoteSettings
            settings.isEnabled = form["enabled"] != nil
            if let port = field("port") {
                guard let number = Int(port), (1...65535).contains(number) else { return .redirect("/server?error=badPort#remote") }
                settings.externalPort = number
            } else {
                settings.externalPort = nil
            }
            settings.publicHost = field("host")
            settings.duckDNSDomain = field("duckdns")
            if let domain = settings.duckDNSDomain {
                guard DuckDNS.subdomain(domain) != nil else { return .redirect("/server?error=badDuckDNS#remote") }
                if let token = field("token") { settings.duckDNSToken = token }
                guard settings.duckDNSToken != nil else { return .redirect("/server?error=duckDNSTokenMissing#remote") }
            } else {
                settings.duckDNSToken = nil
            }
            try await context.saveRemoteSettings(settings)
            return .redirect("/server?saved=1#remote")
        }
    }

    /// A new invitation, shown once: its secret isn't kept, only its hash.
    static func invitationPage(for user: UserRecord, lifetime: TimeInterval, caller: Caller, request: Request,
                               context: ServerContext) async throws -> Response {
        let strings = Strings(request.language)
        let addresses = await context.currentAddresses(requestHost: request.header("Host"))
        let invitation = try context.invite(user, lifetime: lifetime, addresses: addresses)
        Log.info("Invitation made for \(user.name), valid until \(invitation.expiresAt).")
        let isOwn = user.id == caller.user.id
        let message = strings.invitationMessage(server: context.serverName, appStore: appStoreLink, link: invitation.link)
        var page = WebPage(title: strings["invitation"], strings: strings, caller: caller)
        page.add("<h1>\(h(strings.invitationTitle(isOwn ? nil : user.name)))</h1>")
        page.add("<p class=\"hint\">\(h(strings.invitationValidity(invitation.expiresAt)))</p>")
        let code = (try? QRCode(invitation.link).svg(moduleSize: 6, title: strings["invitation"])) ?? ""
        page.add("""
            <div class="invite"><div class="qr">\(code)</div>
            <ol class="steps"><li>\(h(strings["inviteStep1"])) <a href="\(appStoreLink)">App Store</a></li>
            <li>\(h(strings["inviteStep2"]))</li><li>\(h(strings["inviteStep3"]))</li></ol></div>
            <label>\(h(strings["link"]))<input id="invitation-link" readonly value="\(h(invitation.link))"></label>
            <p class="inline"><button type="button" data-copy="invitation-link">\(h(strings["copyLink"]))</button>
            <button type="button" class="quiet" data-share="\(h(message))">\(h(strings["share"]))</button>
            <a class="button quiet" href="\(isOwn ? "/devices" : "/members")">\(h(strings["done"]))</a></p>
            <p class="hint">\(h(strings["inviteOnce"]))</p>
            """)
        if addresses.isEmpty {
            page.add("<p class=\"error\">\(h(strings["noAddress"]))</p>")
        } else {
            page.add("<p class=\"hint\">\(h(strings["inviteAddresses"])) " + addresses.map { "<code>\(h($0))</code>" }.joined(separator: " · ") + "</p>")
        }
        page.add("<script src=\"/admin.js\"></script>")
        return .html(page.html)
    }

    /// "d3:45:fc:…" in groups of two, easier to compare by eye.
    static func grouped(_ fingerprint: String) -> String {
        let characters = Array(fingerprint.uppercased())
        return stride(from: 0, to: characters.count, by: 2).map { (offset: Int) -> String in
            String(characters[offset..<min(offset + 2, characters.count)])
        }.joined(separator: ":")
    }

    /// Copy and share buttons: pages may only load scripts from the server itself.
    static let script = """
    document.querySelectorAll('[data-copy]').forEach(function (button) {
      button.addEventListener('click', function () {
        var field = document.getElementById(button.dataset.copy);
        field.select();
        var done = function () { var text = button.textContent; button.textContent = '✓'; setTimeout(function () { button.textContent = text; }, 1500); };
        if (navigator.clipboard) { navigator.clipboard.writeText(field.value).then(done); } else { document.execCommand('copy'); done(); }
      });
    });
    document.querySelectorAll('[data-share]').forEach(function (button) {
      if (!navigator.share) { button.hidden = true; return; }
      button.addEventListener('click', function () { navigator.share({ text: button.dataset.share }).catch(function () {}); });
    });
    """
}
