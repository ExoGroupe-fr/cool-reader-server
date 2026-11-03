import AppKit
import CoolReaderKit
import ServiceManagement
import SwiftUI

/// SwiftUI's `@State` property wrapper, by a name of its own: the macOS 27 SDK makes `@State` a macro whose plugin
/// only comes with Xcode, and the app builds with the command line tools too.
private typealias ViewState = SwiftUI.State

/// The menu bar panel: the server's state, the setup code until the admin account exists, the libraries, the
/// address devices reach it at, and what to do.
struct PanelView: View {
    @Bindable var controller: ServerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Header(controller: controller)
                if case .failed(let message) = controller.state {
                    FailureBox(message: message, controller: controller)
                }
                if let code = controller.status?.setupCode {
                    SetupBox(code: code) { leave { controller.open(controller.setupURL) } }
                }
                if controller.state == .running, let status = controller.status {
                    LibrarySummary(status: status, isScanning: controller.isScanning, notice: controller.notice)
                    if let address = status.addresses.first {
                        AddressRow(address: address)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Separator()
            VStack(spacing: 0) {
                Button { leave { controller.open(controller.adminURL) } } label: {
                    RowLabel(Strings["openAdmin"], systemImage: "globe")
                }
                .disabled(controller.state != .running)
                Button { leave { Task { await controller.chooseFolder() } } } label: {
                    RowLabel(Strings["addFolder"], systemImage: "folder.badge.plus")
                }
                .disabled(controller.state != .running)
                LoginItemRow(controller: controller)
                DockRow(controller: controller)
                Button { leave { controller.open(controller.logFile) } } label: {
                    RowLabel(Strings["showLog"], systemImage: "doc.text")
                }
                Button { leave { controller.open(controller.dataDirectory) } } label: {
                    RowLabel(Strings["showData"], systemImage: "folder")
                }
            }
            .padding(.horizontal, 6)

            Separator()
            Button { NSApp.terminate(nil) } label: {
                RowLabel(Strings["quit"], shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .buttonStyle(MenuRowStyle())
        .frame(width: 300)
        .background(VisibilityReader { controller.setPanelVisible($0) })
    }

    /// Closes the panel, like a menu once an item is chosen, then does what goes on elsewhere: a browser, the
    /// Finder, a panel to choose a folder.
    private func leave(then action: () -> Void) {
        dismiss()
        action()
    }
}

/// The server's name and whether it runs.
private struct Header: View {
    let controller: ServerController

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status?.name ?? "Cool Reader Server")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(state)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var state: String {
        switch controller.state {
        case .starting: Strings["starting"]
        case .running: Strings.running(port: controller.port)
        case .failed: Strings["stopped"]
        }
    }

    private var color: Color {
        switch controller.state {
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }
}

/// Why the server doesn't run, and a way to try again.
private struct FailureBox: View {
    let message: String
    let controller: ServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(Strings["retry"]) { Task { await controller.start() } }
                .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The six digits that create the admin account, big enough to read from the chair.
private struct SetupBox: View {
    let code: String
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(Strings["setupCode"])
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(code.prefix(3)) \(code.dropFirst(3))")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(2)
                .textSelection(.enabled)
            Text(Strings["setupHint"])
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(Strings["createAdmin"]) { openSetup() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Libraries, series and books, and what the scanner is doing.
private struct LibrarySummary: View {
    let status: ServerInstance.Status
    let isScanning: Bool
    let notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.libraryCount == 0 {
                Text(Strings["noLibrary"])
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Strings.summary(libraries: status.libraryCount, series: status.seriesCount, books: status.bookCount))
            }
            if isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(Strings["scanning"])
                }
                .foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The address to give devices at home, and a button that copies it.
private struct AddressRow: View {
    let address: String
    @ViewState private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings["homeAddress"])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(copied ? Strings["copied"] : Strings["copyAddress"])
            .accessibilityLabel(Strings["copyAddress"])
        }
    }
}

/// Open at login, and what to do when macOS wants it approved.
private struct LoginItemRow: View {
    @Bindable var controller: ServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .frame(width: 18, height: 16)
                Text(Strings["openAtLogin"])
                Spacer(minLength: 8)
                Toggle(Strings["openAtLogin"], isOn: $controller.opensAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if controller.loginItem == .requiresApproval {
                Button(Strings["allowLogin"]) { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.leading, 26)
            }
            if let error = controller.loginItemError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// In the Dock too, or in the menu bar only.
private struct DockRow: View {
    @Bindable var controller: ServerController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dock.rectangle")
                .frame(width: 18, height: 16)
            Text(Strings["showInDock"])
            Spacer(minLength: 8)
            Toggle(Strings["showInDock"], isOn: $controller.showsInDock)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// A menu item's icon, title and keyboard shortcut.
private struct RowLabel: View {
    let title: String
    let systemImage: String?
    let shortcut: String?

    init(_ title: String, systemImage: String? = nil, shortcut: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Color.clear
                }
            }
            .frame(width: 18, height: 16)
            Text(title)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A button that reads like a menu item: the whole row, highlighted under the pointer.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlight, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var highlight: Color {
            guard isEnabled, isHovered else { return .clear }
            return Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)
        }
    }
}

private struct Separator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }
}

/// Tells when the panel's window shows or hides. SwiftUI's onAppear and onDisappear don't follow a menu bar
/// window that opens again.
private struct VisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) == true)
        }
    }
}
