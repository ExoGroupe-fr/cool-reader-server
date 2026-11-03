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
        // LSUIElement does this in the app; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        Task { await controller.start() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                LogFile.rotateIfNeeded()
            }
        }
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
