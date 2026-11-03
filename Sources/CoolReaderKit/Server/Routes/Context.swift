import Crypto
import Foundation
import NIOHTTP1

/// Who is asking: a member, and the device or session they use.
nonisolated struct Caller: Sendable {
    let user: UserRecord
    let device: DeviceRecord?
}

/// Everything the routes share.
nonisolated final class ServerContext: Sendable {
    static let version = "0.1.0"
    static let sessionCookie = "crs_session"

    let config: ServerConfig
    let store: Store
    let images: Images
    let scanner: LibraryScanner
    let agent: MetadataAgent
    let pairings = Pairings()
    let throttle = LoginThrottle()
    let setup: SetupState
    let serverID: String
    let certificate: ServerCertificate
    let network = NetworkState()
    private let basicLogins = VerifiedLogins()

    init(config: ServerConfig, store: Store) throws {
        self.config = config
        self.store = store
        images = Images(cacheDirectory: config.configDirectory.appendingPathComponent("cache"))
        let agent = MetadataAgent(store: store, isEnabled: config.onlineMetadata)
        self.agent = agent
        scanner = LibraryScanner(store: store) { Task { await agent.wake() } }
        if let id = store.setting("server_id") {
            serverID = id
        } else {
            serverID = UUID().uuidString.lowercased()
            try store.setSetting("server_id", serverID)
        }
        setup = SetupState(needed: store.userCount() == 0, file: config.configDirectory.appendingPathComponent("setup-code.txt"))
        certificate = try ServerCertificate.loadOrCreate(in: config.configDirectory.appendingPathComponent("tls"))
    }

    /// The name devices show: the admin's choice, else the configuration's.
    var serverName: String { store.setting("server_name") ?? config.serverName }

    // MARK: - Invitations

    nonisolated struct Invitation: Sendable {
        let secret: String
        let link: String
        let expiresAt: Date
    }

    /// A link that signs one device in as `user`. It carries the addresses to try and the certificate's fingerprint,
    /// so the app trusts this server from the first connection, at home or away.
    func invite(_ user: UserRecord, lifetime: TimeInterval, addresses: [String]) throws -> Invitation {
        let secret = Tokens.make()
        let expiresAt = Date().addingTimeInterval(lifetime)
        _ = try store.addInvitation(userID: user.id, secretHash: Tokens.hash(secret), expiresAt: expiresAt)
        var components = URLComponents()
        components.scheme = "coolreader"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "s", value: serverID),
            URLQueryItem(name: "n", value: serverName),
            URLQueryItem(name: "a", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "fp", value: certificate.fingerprint),
            URLQueryItem(name: "i", value: secret),
        ]
        return Invitation(secret: secret, link: components.string ?? "", expiresAt: expiresAt)
    }

    /// Where devices reach this server, best first, as "host:port": the configured addresses, the one a browser used
    /// (unless it's this machine itself), the network's, then the public ones.
    func addresses(requestHost: String?, local: [String], public publicEndpoints: [String]) -> [String] {
        var addresses = config.publishedAddresses
        if let host = requestHost?.lowercased(), !["localhost", "127.0.0.1", "[::1]"].contains(where: { host == $0 || host.hasPrefix($0 + ":") }) {
            addresses.append(host.contains(":") && !host.hasSuffix("]") ? host : "\(host):\(config.port)")
        }
        addresses += local.map { $0.contains(":") ? "[\($0)]:\(config.port)" : "\($0):\(config.port)" }
        addresses += publicEndpoints
        var seen: Set<String> = []
        return addresses.filter { seen.insert($0).inserted }
    }

    /// Spends an invitation's secret on a device; nil when it's unknown, used or expired. Wrong secrets count as
    /// failed sign-ins for the address.
    func redeem(invitation secret: String, deviceName: String, from address: String?) async throws -> (token: String, user: UserRecord)? {
        let keys = ["invite:" + (address ?? "?")]
        guard await !throttle.isBlocked(keys) else {
            throw HTTPError(status: .tooManyRequests, message: "Too many attempts. Try again in a quarter of an hour.")
        }
        guard let invitation = store.invitation(secretHash: Tokens.hash(secret)), let user = store.user(id: invitation.userID) else {
            await throttle.failed(keys)
            return nil
        }
        let token = Tokens.make()
        guard try store.redeemInvitation(id: invitation.id, deviceName: String(deviceName.prefix(60)), tokenHash: Tokens.hash(token)) else {
            return nil
        }
        return (token, user)
    }

    // MARK: - Signing in

    /// The caller of a request: a device token (app), Basic credentials (OPDS readers) or the web session cookie.
    func caller(_ request: Request) async -> Caller? {
        if let authorization = request.header("Authorization") {
            if authorization.hasPrefix("Bearer ") {
                return device(token: String(authorization.dropFirst(7)))
            }
            if authorization.hasPrefix("Basic "), let decoded = Data(base64Encoded: String(authorization.dropFirst(6))),
               let pair = String(data: decoded, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                let key = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
                if let id = await basicLogins.user(for: key), let user = store.user(id: id) { return Caller(user: user, device: nil) }
                let name = String(pair[..<colon]), password = String(pair[pair.index(after: colon)...])
                guard let user = try? await signIn(name: name, password: password, from: request.remoteAddress) else { return nil }
                await basicLogins.remember(key, user: user.id)
                return Caller(user: user, device: nil)
            }
        }
        if let token = request.cookies[Self.sessionCookie] { return device(token: token) }
        return nil
    }

    private func device(token: String) -> Caller? {
        guard let (device, user) = store.device(tokenHash: Tokens.hash(token)) else { return nil }
        if (device.lastSeenAt ?? .distantPast) < Date().addingTimeInterval(-60) { store.touchDevice(id: device.id) }
        return Caller(user: user, device: device)
    }

    func requireCaller(_ request: Request) async throws -> Caller {
        guard let caller = await caller(request) else { throw HTTPError.unauthorized }
        return caller
    }

    func requireAdmin(_ request: Request) async throws -> Caller {
        let caller = try await requireCaller(request)
        guard caller.user.isAdmin else { throw HTTPError.forbidden }
        return caller
    }

    /// Checks a name and password, ten failures a quarter of an hour at most per address and per name.
    func signIn(name: String, password: String, from address: String?) async throws -> UserRecord {
        let keys = ["name:" + name.lowercased(), "address:" + (address ?? "?")]
        guard await !throttle.isBlocked(keys) else {
            throw HTTPError(status: .tooManyRequests, message: "Too many attempts. Try again in a quarter of an hour.")
        }
        guard let (user, hash) = store.credentials(name: name), Passwords.verify(password, hash: hash) else {
            await throttle.failed(keys)
            throw HTTPError(status: .unauthorized, message: "Wrong name or password.")
        }
        await throttle.succeeded(keys)
        return user
    }

    /// A new device token for `user`, of kind app, web or opds.
    func issueToken(for user: UserRecord, deviceName: String, kind: String) throws -> String {
        let token = Tokens.make()
        _ = try store.addDevice(userID: user.id, name: String(deviceName.prefix(60)), kind: kind, tokenHash: Tokens.hash(token))
        return token
    }

    // MARK: - What a member may see

    func root(of libraryID: Int) -> URL? {
        store.library(id: libraryID).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    func visibleLibrary(_ id: Int?, for caller: Caller) throws -> LibraryRecord {
        guard let id, let library = store.library(id: id), caller.user.canSee(library: id) else { throw HTTPError.notFound }
        return library
    }

    func visibleSeries(_ id: Int?, for caller: Caller) throws -> (SeriesRecord, URL) {
        guard let id, let series = store.series(id: id), caller.user.canSee(library: series.libraryID),
              let root = root(of: series.libraryID) else { throw HTTPError.notFound }
        return (series, root)
    }

    func visibleBook(_ id: Int?, for caller: Caller) throws -> (BookRecord, SeriesRecord, URL) {
        guard let id, let book = store.book(id: id), caller.user.canSee(library: book.libraryID),
              let series = store.series(id: book.seriesID), let root = root(of: book.libraryID) else { throw HTTPError.notFound }
        return (book, series, root)
    }

    func visibleLibraryIDs(for caller: Caller) -> [Int] {
        store.visibleLibraries(for: caller.user).map(\.id)
    }
}

/// The first start: no account yet. A six-digit code, shown in the logs and the Mac app, proves that whoever
/// creates the admin account sits at the server.
actor SetupState {
    private(set) var code: String?
    private let file: URL

    init(needed: Bool, file: URL) {
        self.file = file
        if needed {
            let code = Tokens.code()
            self.code = code
            try? code.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    var isNeeded: Bool { code != nil }

    func matches(_ attempt: String) -> Bool {
        guard let code else { return false }
        return attempt.filter(\.isNumber) == code
    }

    func finish() {
        code = nil
        try? FileManager.default.removeItem(at: file)
    }
}

/// The addresses this server is known at, kept current by its network services: the machine's own on the home
/// network, and the public ones when remote access works.
actor NetworkState {
    private(set) var local: [String] = []
    private(set) var publicEndpoints: [String] = []

    func update(local: [String]) { self.local = local }
    func update(publicEndpoints: [String]) { self.publicEndpoints = publicEndpoints }
}

/// Basic credentials already checked, for ten minutes: OPDS readers send them with every request, and checking
/// a password takes a deliberate half second.
actor VerifiedLogins {
    private var users: [String: (id: Int, until: Date)] = [:]

    func user(for key: String) -> Int? {
        guard let entry = users[key], entry.until > Date() else { return nil }
        return entry.id
    }

    func remember(_ key: String, user: Int) {
        if users.count > 1000 { users = users.filter { $0.value.until > Date() } }
        users[key] = (user, Date().addingTimeInterval(600))
    }
}
