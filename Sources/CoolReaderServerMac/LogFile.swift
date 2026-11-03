import Foundation

/// Where the app keeps the server's data and its log. COOLREADER_CONFIG moves both into one folder, so a test
/// instance leaves nothing in ~/Library.
enum AppPaths {
    private static let testFolder: URL? = ProcessInfo.processInfo.environment["COOLREADER_CONFIG"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

    static let data: URL = testFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cool Reader Server", isDirectory: true)

    static let log: URL = (testFolder ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)).appendingPathComponent("Cool Reader Server.log")
}

/// The server logs to the standard output. In the app, both outputs go to the log file instead, crash messages
/// included. Past 5 MB the file becomes "Cool Reader Server.1.log", replacing the one before, and a new one starts.
enum LogFile {
    static let limit = 5 << 20

    static func start() {
        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Cool Reader Server logs to \(AppPaths.log.path)\n".utf8))
        }
        try? FileManager.default.createDirectory(at: AppPaths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !rotateIfNeeded() { reopen() }
    }

    /// Starts a new file when this one is too big; true when it did.
    @discardableResult
    static func rotateIfNeeded() -> Bool {
        let url = AppPaths.log
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else {
            return false
        }
        let previous = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        reopen()
        return true
    }

    /// Points the standard output and error at the file. A line written meanwhile lands in the old file or the
    /// new one, never nowhere.
    private static func reopen() {
        let descriptor = open(AppPaths.log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
    }
}

/// The app's own lines in the server's log, in the same format.
enum AppLog {
    static func info(_ message: String) { write("info", message) }
    static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardOutput.write(Data("\(Date().ISO8601Format()) [\(level)] \(message)\n".utf8))
    }
}
