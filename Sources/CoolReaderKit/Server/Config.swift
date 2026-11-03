import Foundation

/// Settings from the environment (Docker) and the command line, the latter first.
nonisolated struct ServerConfig: Sendable {
    /// The database, the cache and the setup code. In Docker: /config.
    var configDirectory: URL
    var host = "0.0.0.0"
    var port = 7272
    /// The language and store country the catalogues are asked in.
    var metadataLanguage = "en"
    var metadataCountry = "us"
    var onlineMetadata = true
    /// Minutes between two scans of every library.
    var scanInterval = 30
    /// Libraries to add if missing: name and path (`--library Mangas=/volume1/Mangas`).
    var libraries: [(name: String, path: String)] = []
    var serverName = "Cool Reader Server"

    static func load(arguments: [String], environment: [String: String]) -> ServerConfig {
        var config = ServerConfig(configDirectory: URL(fileURLWithPath: environment["COOLREADER_CONFIG"] ?? "config", isDirectory: true))
        if let host = environment["COOLREADER_HOST"] { config.host = host }
        if let port = environment["COOLREADER_PORT"].flatMap(Int.init) { config.port = port }
        if let language = environment["COOLREADER_METADATA_LANGUAGE"] { config.metadataLanguage = language }
        if let country = environment["COOLREADER_METADATA_COUNTRY"] { config.metadataCountry = country }
        if let online = environment["COOLREADER_ONLINE_METADATA"] { config.onlineMetadata = !["0", "false", "no"].contains(online.lowercased()) }
        if let minutes = environment["COOLREADER_SCAN_INTERVAL"].flatMap(Int.init) { config.scanInterval = max(1, minutes) }
        if let name = environment["COOLREADER_NAME"] { config.serverName = name }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--config": value.map { config.configDirectory = URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--host": value.map { config.host = $0 }; index += 1
            case "--port": value.flatMap(Int.init).map { config.port = $0 }; index += 1
            case "--metadata-language": value.map { config.metadataLanguage = $0 }; index += 1
            case "--metadata-country": value.map { config.metadataCountry = $0 }; index += 1
            case "--offline": config.onlineMetadata = false
            case "--library":
                if let value, let equals = value.firstIndex(of: "=") {
                    config.libraries.append((String(value[..<equals]), String(value[value.index(after: equals)...])))
                }
                index += 1
            default: break
            }
            index += 1
        }
        return config
    }
}
