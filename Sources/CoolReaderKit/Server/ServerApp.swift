import Foundation
import NIOConcurrencyHelpers

/// The command line: `cool-reader-server [options]` runs the server until it's stopped (Ctrl-C, `docker stop`);
/// `cool-reader-server invite <member> [options]` prints an invitation link for a member.
public enum CoolReaderServerApp {
    public static func run(arguments: [String] = CommandLine.arguments,
                           environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        if arguments.count > 2, arguments[1] == "invite" {
            print(try invite(name: arguments[2], arguments: arguments, environment: environment))
            return
        }
        let server = try await ServerInstance.start(arguments: arguments, environment: environment)
        await waitForStopSignal()
        Log.info("Stopping.")
        await server.stop()
    }

    /// An invitation for the member named `name`, valid two days.
    static func invite(name: String, arguments: [String], environment: [String: String]) throws -> String {
        let config = ServerConfig.load(arguments: arguments, environment: environment)
        let store = try Store(path: config.configDirectory.appendingPathComponent("library.sqlite").path)
        guard store.userCount() > 0 else { return "Create the admin account first: open the server's page in a browser." }
        guard let (user, _) = store.credentials(name: name) else {
            return "No member is called « \(name) ». Members: \(store.users().map(\.name).joined(separator: ", "))."
        }
        let context = try ServerContext(config: config, store: store)
        let addresses = context.addresses(requestHost: nil, local: NetworkInterfaces.localAddresses(), public: context.configuredPublicEndpoints)
        let invitation = try context.invite(user, lifetime: 48 * 3600, addresses: addresses)
        return """
            Invitation for \(user.name), valid until \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened)), \
            for one device. Open it on the iPhone or iPad where Cool Reader is installed:

            \(invitation.link)
            """
    }

    /// Ctrl-C or SIGTERM: the server then removes its port mapping and its Bonjour record before it quits.
    private static func waitForStopSignal() async {
        let signals = [SIGINT, SIGTERM]
        for number in signals { signal(number, SIG_IGN) }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let sources = signals.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield() }
            source.resume()
            return source
        }
        for await _ in stream { break }
        sources.forEach { $0.cancel() }
    }
}

/// A running server: its settings, database, scans, and HTTP with HTTPS on one port. The command line and the
/// Mac app each start one.
public final class ServerInstance: Sendable {
    /// What the Mac app shows.
    public struct Status: Sendable {
        public var name: String
        public var version: String
        public var port: Int
        /// The six digits that create the admin account, until it exists.
        public var setupCode: String?
        public var libraryCount: Int
        public var seriesCount: Int
        public var bookCount: Int
        public var memberCount: Int
        /// "host:port", the home network's first, then the public ones.
        public var addresses: [String]
        /// SHA-256 of the certificate, lowercase hex.
        public var fingerprint: String
        public var configDirectory: URL
    }

    let context: ServerContext
    private let port: Int
    private let tasks: NIOLockedValueBox<[Task<Void, Never>]>

    private init(context: ServerContext, port: Int, tasks: [Task<Void, Never>]) {
        self.context = context
        self.port = port
        self.tasks = NIOLockedValueBox(tasks)
    }

    /// Starts the server, once it listens: the port is taken, or it throws. `configDirectory` wins over the
    /// arguments' and the environment's.
    public static func start(arguments: [String] = [], environment: [String: String] = [:],
                             configDirectory: URL? = nil) async throws -> ServerInstance {
        var loaded = ServerConfig.load(arguments: arguments, environment: environment)
        if let configDirectory { loaded.configDirectory = configDirectory }
        let config = loaded
        try FileManager.default.createDirectory(at: config.configDirectory, withIntermediateDirectories: true)
        MetadataLocale.language = config.metadataLanguage
        MetadataLocale.country = config.metadataCountry

        let store = try Store(path: config.configDirectory.appendingPathComponent("library.sqlite").path)
        for library in config.libraries {
            let path = URL(fileURLWithPath: library.path).standardizedFileURL.path
            if !store.libraries().contains(where: { $0.path == path }) { _ = try store.addLibrary(name: library.name, path: path) }
        }
        let context = try ServerContext(config: config, store: store)

        Log.info("Cool Reader Server \(ServerContext.version), data in \(config.configDirectory.standardizedFileURL.path)")
        Log.info("Certificate fingerprint (SHA-256): \(context.certificate.fingerprint)")
        if let code = await context.setup.code {
            Log.info("First start: open http://<this machine>:\(config.port)/setup and type the setup code \(code).")
        }
        if !config.onlineMetadata { Log.info("Online metadata is off: series keep their folder names.") }

        var router = Router()
        APIRoutes.add(to: &router, context: context)
        OPDSRoutes.add(to: &router, context: context)
        AdminRoutes.add(to: &router, context: context)
        InvitationRoutes.add(to: &router, context: context)
        let routes = router

        let (listening, listener) = AsyncStream<Result<Int, any Error>>.makeStream()
        let http = Task {
            do {
                try await HTTPServer.run(host: config.host, port: config.port, tls: context.certificate.sslContext, handler: { request in
                    await handle(request, routes: routes)
                }, onListening: { port in
                    listener.yield(.success(port))
                })
            } catch {
                listener.yield(.failure(error))
            }
            listener.finish()
        }
        var port = config.port
        for await result in listening {
            switch result {
            case .success(let bound): port = bound
            case .failure(let error): throw error
            }
            break
        }
        Log.info("Listening on port \(port), HTTP and HTTPS.")
        await context.advertising.start(name: context.serverName, port: port,
                                        txt: ["id": context.serverID, "v": ServerContext.version, "api": "1"])
        await context.remoteAccess.start()

        let scans = Task {
            while !Task.isCancelled {
                await context.scanner.scanAll()
                try? await Task.sleep(for: .seconds(config.scanInterval * 60))
            }
        }
        return ServerInstance(context: context, port: port, tasks: [http, scans])
    }

    /// Plain HTTP only from the home network: from anywhere else, pages move to HTTPS and the rest is refused,
    /// so passwords and tokens never cross the internet in clear.
    static func handle(_ request: Request, routes: Router) async -> Response {
        if !request.isSecure, !request.isFromLocalNetwork {
            if request.method == .GET || request.method == .HEAD, let host = request.header("Host") {
                return Response(status: .temporaryRedirect, headers: ["Location": "https://\(host)\(request.uri)"])
            }
            return .error(.forbidden, "Use https:// to reach this server from outside the home network.")
        }
        return await routes.handle(request)
    }

    public func status() async -> Status {
        let libraries = context.store.libraries()
        return Status(name: context.serverName, version: ServerContext.version, port: port, setupCode: await context.setup.code,
                      libraryCount: libraries.count, seriesCount: libraries.reduce(0) { $0 + $1.seriesCount },
                      bookCount: libraries.reduce(0) { $0 + $1.bookCount }, memberCount: context.store.userCount(),
                      addresses: await context.currentAddresses(requestHost: nil),
                      fingerprint: context.certificate.fingerprint, configDirectory: context.config.configDirectory)
    }

    /// Adds a folder as a library, unless it is one already, and scans it.
    public func addLibrary(name: String, path: String) async throws {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !context.store.libraries().contains(where: { $0.path == path }) else { return }
        let id = try context.store.addLibrary(name: name, path: path)
        await context.scanner.enqueue(id)
    }

    /// Stops listening and scanning, says goodbye on Bonjour and closes the router's port.
    public func stop() async {
        let running = tasks.withLockedValue { tasks in
            defer { tasks = [] }
            return tasks
        }
        running.forEach { $0.cancel() }
        await context.advertising.stop()
        await context.remoteAccess.stop()
        for task in running { await task.value }
    }
}
