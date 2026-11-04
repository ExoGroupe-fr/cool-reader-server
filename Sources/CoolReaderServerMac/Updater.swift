import AppKit
import CoolReaderKit
import Foundation
import Observation
import Security

/// Updates from the GitHub releases, like Plex Media Server's: at start and once a day the app looks for a newer
/// version, and the menu offers to install it. The new app must be signed with ExoGroupe's Developer ID, its
/// certificate from Apple, and carry this app's identifier before it takes this one's place; the app then starts
/// again. Nothing else is downloaded or run.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case available(AppRelease)
        case installing
        case failed(String)
    }

    private(set) var state = State.idle

    nonisolated static let feed = URL(string: "https://api.github.com/repos/ExoGroupe-fr/cool-reader-server/releases/latest")!
    /// EXOGROUPE's team: the releases' signature.
    nonisolated static let team = "7KT36YFDKQ"
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func checkDaily() {
        Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check() async {
        guard state != .installing else { return }
        var request = URLRequest(url: Self.feed, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CoolReaderServer/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let release = AppRelease.parse(data), AppRelease.isNewer(release.version, than: current) else { return }
        if state != .available(release) {
            AppLog.info("Version \(release.version) is out: the menu offers it.")
            state = .available(release)
        }
    }

    /// Downloads, checks, swaps the apps, then quits for the new one to start.
    func install() async {
        guard case .available(let release) = state else { return }
        state = .installing
        do {
            let (zip, _) = try await URLSession.shared.download(from: release.download)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoolReaderServerUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
            guard let app = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("the archive holds no app") }
            try Self.verify(app)
            let target = Bundle.main.bundleURL
            // The running app goes to the Trash: it keeps running from there until it quits.
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            try FileManager.default.moveItem(at: app, to: target)
            AppLog.info("Version \(release.version) installed: starting again.")
            Self.relaunch(target)
        } catch {
            AppLog.error("The update couldn't be installed: \(error)")
            state = .failed("\(error)")
        }
    }

    /// Signed with ExoGroupe's Developer ID, the chain up to Apple, the same bundle identifier as this app.
    nonisolated static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError("the app can't be read") }
        var requirement: SecRequirement?
        let identifier = Bundle.main.bundleIdentifier ?? "com.pookee.CoolReaderServer"
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("the signature can't be checked")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else { throw UpdateError("its signature isn't ExoGroupe's (\(status))") }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(tool) failed (\(process.terminationStatus))") }
    }

    /// A shell waits for this app to quit, which stops the server cleanly, then opens the new one.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
