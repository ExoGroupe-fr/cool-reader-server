import Foundation
import NIOHTTP1

/// What the web admin does, for Cool Reader signed in as an admin, like Plex's settings in its apps: libraries and
/// their scans, members and their invitations, devices, the server's settings, and deleting books when it is allowed.
/// Every call needs an admin's token; anyone else gets 403.
nonisolated enum AdminAPIRoutes {
    struct LibraryInfo: Codable {
        var id: Int
        var name: String
        var path: String
        var seriesCount: Int
        var bookCount: Int
        var lastScanAt: Date?
        /// "unreachable" when the folder couldn't be read: its books are kept.
        var lastError: String?
    }

    struct NewLibrary: Decodable {
        var name: String
        var path: String
    }

    struct MemberInfo: Codable {
        var id: Int
        var name: String
        var isAdmin: Bool
        var allLibraries: Bool
        var libraryIDs: [Int]
        /// false for a member who only gets in with an invitation.
        var hasPassword: Bool
    }

    struct NewMember: Decodable {
        var name: String
        var password: String?
        var allLibraries: Bool?
        var libraryIDs: [Int]?
    }

    struct MemberChange: Decodable {
        var allLibraries: Bool?
        var libraryIDs: [Int]?
        var password: String?
    }

    struct InvitationInfo: Codable {
        var id: Int?
        var memberID: Int
        var memberName: String
        /// coolreader://connect?…, only when it is made: the server keeps its hash alone.
        var link: String?
        var expiresAt: Date
    }

    struct NewMemberResult: Codable {
        var member: MemberInfo
        var invitation: InvitationInfo
    }

    struct DeviceInfo: Codable {
        var id: Int
        var memberID: Int
        var memberName: String
        var name: String
        /// app, opds or web.
        var kind: String
        var createdAt: Date
        var lastSeenAt: Date?
    }

    struct Approval: Decodable {
        var code: String
        var memberID: Int
    }

    struct ServerSettings: Codable {
        var name: String
        var version: String
        var addresses: [String]
        var allowDeletion: Bool
        var comicVineKeySet: Bool
        var scanning: Bool
        var pendingMatches: Int
        var remoteAccess: RemoteSettings
        var remoteStatus: RemoteAccessStatus
    }

    /// The remote access settings without the DuckDNS token, which is only ever sent.
    struct RemoteSettings: Codable {
        var enabled: Bool
        var port: Int?
        var host: String?
        var duckDNSDomain: String?
        var duckDNSTokenSet: Bool
    }

    /// Fields left out stay as they are. `comicVineKey: ""` removes the key; in `remoteAccess`, `port: 0` and empty
    /// strings clear a field.
    struct ServerChange: Decodable {
        var name: String?
        var allowDeletion: Bool?
        var comicVineKey: String?
        var remoteAccess: RemoteChange?
    }

    struct RemoteChange: Decodable {
        var enabled: Bool?
        var port: Int?
        var host: String?
        var duckDNSDomain: String?
        var duckDNSToken: String?
    }

    static func add(to router: inout Router, context: ServerContext) {
        // MARK: Libraries

        router.add(.GET, "/api/v1/admin/libraries") { request in
            _ = try await context.requireAdmin(request)
            return .json(context.store.libraries().map(info))
        }

        router.add(.POST, "/api/v1/admin/libraries") { request in
            _ = try await context.requireAdmin(request)
            let new = try APIRoutes.decode(NewLibrary.self, request)
            let name = new.name.trimmingCharacters(in: .whitespaces)
            let path = URL(fileURLWithPath: new.path.trimmingCharacters(in: .whitespaces)).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard !name.isEmpty else { throw HTTPError.badRequest("The library needs a name.") }
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HTTPError.badRequest("That folder doesn't exist on the server.")
            }
            guard !context.store.libraries().contains(where: { $0.path == path }) else { throw HTTPError.badRequest("That folder is a library already.") }
            let id = try context.store.addLibrary(name: String(name.prefix(60)), path: path)
            await context.scanner.enqueue(id)
            guard let library = context.store.library(id: id) else { throw HTTPError.notFound }
            return .json(info(library))
        }

        router.add(.POST, "/api/v1/admin/libraries/:id/scan") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id"), context.store.library(id: id) != nil else { throw HTTPError.notFound }
            await context.scanner.enqueue(id)
            return .json(["status": "scanning"])
        }

        // The library's folder is left as it is: only the server forgets it.
        router.add(.DELETE, "/api/v1/admin/libraries/:id") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id"), context.store.library(id: id) != nil else { throw HTTPError.notFound }
            try context.store.removeLibrary(id: id)
            return .json(["status": "removed"])
        }

        // MARK: Members and invitations

        router.add(.GET, "/api/v1/admin/members") { request in
            _ = try await context.requireAdmin(request)
            return .json(context.store.users().map { info($0, context: context) })
        }

        // A member without a password reads with Cool Reader only: the invitation that comes back signs their device in.
        router.add(.POST, "/api/v1/admin/members") { request in
            let caller = try await context.requireAdmin(request)
            let new = try APIRoutes.decode(NewMember.self, request)
            let name = new.name.trimmingCharacters(in: .whitespaces)
            let password = new.password ?? ""
            guard !name.isEmpty else { throw HTTPError.badRequest("The member needs a name.") }
            guard password.isEmpty || password.count >= 8 else { throw HTTPError.badRequest("The password needs at least 8 characters.") }
            guard context.store.credentials(name: name) == nil else { throw HTTPError.badRequest("That name is taken.") }
            let id = try context.store.createUser(name: name, passwordHash: password.isEmpty ? "" : Passwords.hash(password), isAdmin: false,
                                                  allLibraries: new.allLibraries ?? false, libraryIDs: new.libraryIDs ?? [])
            guard let user = context.store.user(id: id) else { throw HTTPError.notFound }
            let invitation = try await invite(user, caller: caller, request: request, context: context)
            return .json(NewMemberResult(member: info(user, context: context), invitation: invitation))
        }

        router.add(.PATCH, "/api/v1/admin/members/:id") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id"), let user = context.store.user(id: id) else { throw HTTPError.notFound }
            let change = try APIRoutes.decode(MemberChange.self, request)
            if let password = change.password {
                guard password.count >= 8 else { throw HTTPError.badRequest("The password needs at least 8 characters.") }
                try context.store.setPassword(userID: id, hash: Passwords.hash(password))
            }
            if !user.isAdmin, change.allLibraries != nil || change.libraryIDs != nil {
                try context.store.setLibraries(userID: id, all: change.allLibraries ?? user.allLibraries, libraryIDs: change.libraryIDs ?? user.libraryIDs)
            }
            guard let saved = context.store.user(id: id) else { throw HTTPError.notFound }
            return .json(info(saved, context: context))
        }

        router.add(.DELETE, "/api/v1/admin/members/:id") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id"), let user = context.store.user(id: id) else { throw HTTPError.notFound }
            guard !user.isAdmin else { throw HTTPError(status: .forbidden, message: "The admin account can't be deleted.") }
            try context.store.removeUser(id: id)
            return .json(["status": "removed"])
        }

        // Valid two days for a member, half an hour for the admin's own device.
        router.add(.POST, "/api/v1/admin/members/:id/invitations") { request in
            let caller = try await context.requireAdmin(request)
            guard let id = request.parameter("id"), let user = context.store.user(id: id) else { throw HTTPError.notFound }
            return .json(try await invite(user, caller: caller, request: request, context: context))
        }

        router.add(.GET, "/api/v1/admin/invitations") { request in
            _ = try await context.requireAdmin(request)
            let users = context.store.users()
            return .json(context.store.openInvitations().map { invitation in
                InvitationInfo(id: invitation.id, memberID: invitation.userID, memberName: users.first { $0.id == invitation.userID }?.name ?? "?",
                               link: nil, expiresAt: invitation.expiresAt)
            })
        }

        router.add(.DELETE, "/api/v1/admin/invitations/:id") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id") else { throw HTTPError.notFound }
            try context.store.removeInvitation(id: id)
            return .json(["status": "removed"])
        }

        // MARK: Devices

        router.add(.GET, "/api/v1/admin/devices") { request in
            _ = try await context.requireAdmin(request)
            let users = context.store.users()
            return .json(context.store.devices().map { device in
                DeviceInfo(id: device.id, memberID: device.userID, memberName: users.first { $0.id == device.userID }?.name ?? "?",
                           name: device.name, kind: device.kind, createdAt: device.createdAt, lastSeenAt: device.lastSeenAt)
            })
        }

        router.add(.DELETE, "/api/v1/admin/devices/:id") { request in
            _ = try await context.requireAdmin(request)
            guard let id = request.parameter("id") else { throw HTTPError.notFound }
            try context.store.removeDevice(id: id)
            return .json(["status": "revoked"])
        }

        /// The code a device shows when it pairs on the home network (POST /api/v1/pair), approved for a member.
        router.add(.POST, "/api/v1/admin/pairings/approve") { request in
            _ = try await context.requireAdmin(request)
            let approval = try APIRoutes.decode(Approval.self, request)
            guard let user = context.store.user(id: approval.memberID) else { throw HTTPError.notFound }
            guard let device = try await context.pairings.approve(code: approval.code, user: user, store: context.store) else {
                throw HTTPError(status: .notFound, message: "No device shows that code now.")
            }
            return .json(["device": device])
        }

        // MARK: Server

        router.add(.GET, "/api/v1/admin/server") { request in
            _ = try await context.requireAdmin(request)
            return .json(await settings(request: request, context: context))
        }

        router.add(.PATCH, "/api/v1/admin/server") { request in
            _ = try await context.requireAdmin(request)
            let change = try APIRoutes.decode(ServerChange.self, request)
            if let name = change.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                try context.store.setSetting("server_name", String(name.prefix(60)))
                await context.advertising.rename(context.serverName)
            }
            if let allowed = change.allowDeletion { try context.setAllowsDeletion(allowed) }
            if let key = change.comicVineKey?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try await context.setComicVineKey(key.isEmpty ? nil : String(key.prefix(100)))
            }
            if let remote = change.remoteAccess {
                let saved = context.remoteSettings
                func text(_ value: String?, _ current: String?) -> String? {
                    guard let value else { return current }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                let port = remote.port.map { $0 == 0 ? nil : String($0) } ?? saved.externalPort.map(String.init)
                if let problem = try await context.updateRemoteSettings(
                    enabled: remote.enabled ?? saved.isEnabled, port: port, host: text(remote.host, saved.publicHost),
                    duckDNS: text(remote.duckDNSDomain, saved.duckDNSDomain), token: text(remote.duckDNSToken, nil)) {
                    throw HTTPError.badRequest(Strings("en")[problem])
                }
            }
            return .json(await settings(request: request, context: context))
        }

        // MARK: Deleting books

        router.add(.DELETE, "/api/v1/admin/books/:id") { request in
            let caller = try await context.requireAdmin(request)
            let (book, _, _) = try context.visibleBook(request.parameter("id"), for: caller)
            try context.delete(book)
            return .json(["status": "deleted"])
        }

        /// Every book of a series, its folder left with whatever else it holds.
        router.add(.DELETE, "/api/v1/admin/series/:id") { request in
            let caller = try await context.requireAdmin(request)
            let (series, _) = try context.visibleSeries(request.parameter("id"), for: caller)
            for book in context.store.books(seriesID: series.id) { try context.delete(book) }
            return .json(["status": "deleted"])
        }
    }

    // MARK: - Pieces

    static func info(_ library: LibraryRecord) -> LibraryInfo {
        LibraryInfo(id: library.id, name: library.name, path: library.path, seriesCount: library.seriesCount, bookCount: library.bookCount,
                    lastScanAt: library.lastScanAt, lastError: library.lastError)
    }

    static func info(_ user: UserRecord, context: ServerContext) -> MemberInfo {
        MemberInfo(id: user.id, name: user.name, isAdmin: user.isAdmin, allLibraries: user.allLibraries, libraryIDs: user.libraryIDs,
                   hasPassword: context.store.credentials(name: user.name)?.1.isEmpty == false)
    }

    private static func invite(_ user: UserRecord, caller: Caller, request: Request, context: ServerContext) async throws -> InvitationInfo {
        let lifetime: TimeInterval = user.id == caller.user.id ? 30 * 60 : 48 * 3600
        let invitation = try context.invite(user, lifetime: lifetime, addresses: await context.currentAddresses(requestHost: request.header("Host")))
        Log.info("Invitation made for \(user.name) from the API, valid until \(invitation.expiresAt).")
        return InvitationInfo(id: nil, memberID: user.id, memberName: user.name, link: invitation.link, expiresAt: invitation.expiresAt)
    }

    private static func settings(request: Request, context: ServerContext) async -> ServerSettings {
        let remote = context.remoteSettings
        return ServerSettings(
            name: context.serverName, version: ServerContext.version,
            addresses: await context.currentAddresses(requestHost: request.header("Host")), allowDeletion: context.allowsDeletion,
            comicVineKeySet: ComicVineClient.key != nil, scanning: await context.scanner.isScanning,
            pendingMatches: context.store.pendingSeries(limit: 10_000).count,
            remoteAccess: RemoteSettings(enabled: remote.isEnabled, port: remote.externalPort, host: remote.publicHost,
                                         duckDNSDomain: remote.duckDNSDomain, duckDNSTokenSet: remote.duckDNSToken != nil),
            remoteStatus: await context.remoteAccess.status)
    }
}
