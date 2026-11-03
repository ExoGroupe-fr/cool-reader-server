import AppKit
import CoolReaderKit
import NIOCore
import Observation
import ServiceManagement

/// Runs the server in the app's process and keeps what the panel shows, refreshed every few seconds while the
/// panel is open.
@MainActor @Observable
final class ServerController {
    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    private(set) var state = State.starting
    private(set) var status: ServerInstance.Status?
    private(set) var isScanning = false
    /// What became of the last folder added, until the panel has shown it.
    private(set) var notice: String?
    private(set) var loginItem = SMAppService.mainApp.status
    private(set) var loginItemError: String?

    let dataDirectory = AppPaths.data
    let logFile = AppPaths.log
    /// The port asked for: the one the server listens on, unless it couldn't start.
    let requestedPort: Int

    @ObservationIgnored private var instance: ServerInstance?
    @ObservationIgnored private var isStarting = false
    private let environment: [String: String]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Folders handed to the app before the server listens.
    @ObservationIgnored private var waitingFolders: [URL] = []
    @ObservationIgnored private var noticeShown = false

    init() {
        environment = Self.serverEnvironment()
        requestedPort = environment["COOLREADER_PORT"].flatMap(Int.init) ?? 7272
    }

    /// The process's environment, where COOLREADER_PORT and the other settings can be set for testing, with the
    /// catalogues asked in the Mac's language and store country unless it says otherwise.
    private static func serverEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["COOLREADER_METADATA_LANGUAGE"] == nil,
           let language = Locale(identifier: Locale.preferredLanguages.first ?? "en").language.languageCode?.identifier {
            environment["COOLREADER_METADATA_LANGUAGE"] = language
        }
        if environment["COOLREADER_METADATA_COUNTRY"] == nil, let region = Locale.current.region?.identifier, region.count == 2 {
            environment["COOLREADER_METADATA_COUNTRY"] = region.lowercased()
        }
        return environment
    }

    var port: Int { status?.port ?? requestedPort }
    var adminURL: URL { URL(string: "http://localhost:\(port)/")! }
    var setupURL: URL { URL(string: "http://localhost:\(port)/setup")! }

    func start() async {
        guard instance == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        state = .starting
        do {
            let instance = try await ServerInstance.start(environment: environment, configDirectory: dataDirectory)
            self.instance = instance
            state = .running
            await refresh()
            let folders = waitingFolders
            waitingFolders = []
            for folder in folders { await addLibrary(folder) }
        } catch {
            AppLog.error("The server couldn't start: \(error)")
            if let error = error as? IOError, error.errnoCode == EADDRINUSE {
                state = .failed(Strings.portInUse(requestedPort))
            } else {
                state = .failed(Strings.startFailed("\(error)"))
            }
        }
    }

    /// The running server, for the app to stop as it quits: its port mapping and Bonjour record go with it.
    func detachServer() -> ServerInstance? {
        refreshing?.cancel()
        refreshing = nil
        defer { instance = nil }
        return instance
    }

    func refresh() async {
        guard let instance else { return }
        status = await instance.status()
        isScanning = await instance.isScanning
    }

    func setPanelVisible(_ visible: Bool) {
        if visible {
            loginItem = SMAppService.mainApp.status
            noticeShown = notice != nil
            guard refreshing == nil else { return }
            refreshing = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else {
            refreshing?.cancel()
            refreshing = nil
            loginItemError = nil
            if noticeShown {
                notice = nil
                noticeShown = false
            }
        }
    }

    // MARK: - Libraries

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings["choosePrompt"]
        panel.message = Strings["chooseMessage"]
        NSApp.activate()
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
            // In front even if macOS keeps another app active: a menu bar app has no window to come back to.
            panel.orderFrontRegardless()
        }
        guard response == .OK, let folder = panel.url else { return }
        await addLibrary(folder)
    }

    /// Adds a folder as a library named after it, once the server listens.
    func addLibrary(_ folder: URL) async {
        guard let instance else {
            waitingFolders.append(folder)
            return
        }
        let name = FileManager.default.displayName(atPath: folder.path)
        let before = await instance.status().libraryCount
        do {
            try await instance.addLibrary(name: name, path: folder.path)
            await refresh()
            if (status?.libraryCount ?? before) > before {
                AppLog.info("Library « \(name) » added from the Mac app: \(folder.path)")
                notice = Strings.added(name)
            } else {
                notice = Strings.alreadyAdded(name)
            }
        } catch {
            AppLog.error("Library « \(name) » couldn't be added: \(error)")
            notice = Strings.addFailed(name, "\(error)")
        }
    }

    // MARK: - Open at login

    var opensAtLogin: Bool {
        get { loginItem == .enabled || loginItem == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = Strings.loginItemFailed(error.localizedDescription)
            }
            loginItem = SMAppService.mainApp.status
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
