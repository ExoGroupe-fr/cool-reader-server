import AppKit
import SwiftUI

/// Cool Reader Server in the menu bar, like Plex Media Server on a Mac: the app runs the server and says what to do
/// with it.
@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: delegate.controller)
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Books in the menu bar, a warning sign when the server couldn't start.
struct MenuBarIcon: View {
    let controller: ServerController

    var body: some View {
        Group {
            if case .failed = controller.state {
                Image(systemName: "exclamationmark.triangle")
            } else {
                Image(systemName: "books.vertical")
            }
        }
        .accessibilityLabel(Text(verbatim: "Cool Reader Server"))
    }
}

/// Starts the server once the app is up, and stops it before the app quits: from the panel, at logout, or on
/// SIGTERM.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ServerController()
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        LogFile.start()
        // LSUIElement keeps the app out of the Dock while it starts; it comes in now unless the user turned it off.
        DockIcon.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        Task {
            await controller.start()
            askToOpenAtLogin()
        }
        controller.updater.checkDaily()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                LogFile.rotateIfNeeded()
            }
        }
    }

    /// Once, at the first start: a server is of use when it runs, so the app offers to open with the Mac. The menu's
    /// switch changes it later.
    private func askToOpenAtLogin() {
        let asked = "AskedToOpenAtLogin"
        guard !UserDefaults.standard.bool(forKey: asked), !controller.opensAtLogin else { return }
        UserDefaults.standard.set(true, forKey: asked)
        let alert = NSAlert()
        alert.messageText = Strings["openAtLoginQuestion"]
        alert.informativeText = Strings["openAtLoginExplain"]
        alert.addButton(withTitle: Strings["openAtLoginYes"])
        alert.addButton(withTitle: Strings["notNow"])
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { controller.opensAtLogin = true }
    }

    /// The Dock icon opens the site, as Plex Media Server opens Plex.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controller.state == .running { controller.open(controller.adminURL) }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: Strings["openInBrowser"], action: #selector(openSite), keyEquivalent: "").target = self
        menu.addItem(withTitle: Strings["addFolder"], action: #selector(addFolder), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openSite() {
        controller.open(controller.adminURL)
    }

    @objc private func addFolder() {
        Task { await controller.chooseFolder() }
    }

    /// Folders dropped on the app's icon, or opened with it, become libraries.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        Task {
            for folder in folders { await controller.addLibrary(folder) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = controller.detachServer() else { return .terminateNow }
        AppLog.info("Stopping.")
        Task.detached {
            await server.stop()
            Self.replyToTerminate()
        }
        // A server that doesn't stop in ten seconds doesn't keep the Mac from logging out.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { Self.replyToTerminate() }
        return .terminateLater
    }

    /// The reply goes through the run loop, not the main actor: terminate(_:) may have been called from a task on
    /// the main actor (the signal handler's), and it keeps the main actor busy while it waits for this reply.
    private nonisolated static func replyToTerminate() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
