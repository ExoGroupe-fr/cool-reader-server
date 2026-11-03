import Foundation

/// Starts the server: settings, database, libraries from the command line, routes, scans, and HTTP.
public enum CoolReaderServerApp {
    public static func run(arguments: [String] = CommandLine.arguments,
                           environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let config = ServerConfig.load(arguments: arguments, environment: environment)
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
        if let code = await context.setup.code {
            Log.info("First start: open http://<this machine>:\(config.port)/setup and type the setup code \(code).")
        }
        if !config.onlineMetadata { Log.info("Online metadata is off: series keep their folder names.") }

        var router = Router()
        APIRoutes.add(to: &router, context: context)
        OPDSRoutes.add(to: &router, context: context)
        AdminRoutes.add(to: &router, context: context)
        let routes = router

        Task {
            while true {
                await context.scanner.scanAll()
                try? await Task.sleep(for: .seconds(config.scanInterval * 60))
            }
        }

        try await HTTPServer.run(host: config.host, port: config.port, handler: { request in
            await routes.handle(request)
        }, onListening: { port in
            Log.info("Listening on port \(port).")
        })
    }
}
