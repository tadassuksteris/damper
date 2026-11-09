import AppKit
import DamperCore
import Observation
import SwiftUI

@main
enum DamperMain {
    @MainActor static func main() {
        if SystemAudioAccessPermission.handleFreshProcessArguments() { return }
        if CommandLine.arguments.contains("--verify-test-audio") {
            #if DEBUG
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    print(try await AudioIntegrationCheck().run()); exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Audio check failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            application.run()
            return
            #else
            FileHandle.standardError.write(Data("--verify-test-audio requires a debug build\n".utf8))
            exit(2)
            #endif
        }
        if CommandLine.arguments.contains("--diagnostics") {
            printDiagnostics()
            return
        }
        if handOffToRunningInstance() { return }
        DamperApp.main()
    }

    /// Two copies would tap the same apps and overwrite each other's preferences, so the later
    /// one reopens the earlier one and exits.
    @MainActor private static func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let launch = NSRunningApplication.current.launchDate ?? .distantFuture
        let earlier = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { other in
            other.processIdentifier != getpid() &&
                (other.launchDate ?? .distantPast, other.processIdentifier) < (launch, getpid())
        }
        guard let earlier else { return false }
        if let url = earlier.bundleURL { NSWorkspace.shared.open(url) } else { earlier.activate() }
        return true
    }

    @MainActor private static func printDiagnostics() {
        let backend = CoreAudioBackend()
        var latest = AudioSnapshot()
        backend.onSnapshot = { latest = $0 }
        do {
            try backend.startMonitoring()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            backend.stop()
            let document: [String: Any] = [
                "mode": "discovery only; no audio capture or output changes",
                "defaultOutputID": latest.defaultOutputID.map { $0 as Any } ?? NSNull(),
                "outputUnsupportedReason": latest.outputUnsupportedReason.map { $0 as Any } ?? NSNull(),
                "outputs": latest.outputs.map { ["id": $0.id, "name": $0.name,
                    "volume": $0.volume.map { $0 as Any } ?? NSNull(), "muted": $0.muted.map { $0 as Any } ?? NSNull(),
                    "symbol": $0.identity.symbolName] as [String: Any] },
                "apps": latest.clients.map { ["id": $0.id, "name": $0.name, "runningOutput": $0.isRunningOutput,
                    "controllable": $0.isControllable, "reason": $0.unavailableReason.map { $0 as Any } ?? NSNull(),
                    "processCount": $0.processObjectIDs.count] as [String: Any] }
            ]
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("Discovery failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct DamperApp: App {
    @MainActor static let model = MixerModel(backend: CoreAudioBackend())

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var panelLayout = PanelLayout()

    var body: some Scene {
        let model = Self.model
        MenuBarExtra {
            MixerPanel(model: model, layout: panelLayout, openSettings: { delegate.showSettings() },
                       quit: { NSApplication.shared.terminate(nil) })
                .fixedSize(horizontal: false, vertical: true)
                .background(PanelWindowObserver { window in
                    panelLayout.availableHeight = (window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude) - PanelMetrics.screenMargin
                    if !model.isPanelOpen { model.beginPanelSession() }
                    Task { await model.refreshAccessPermission() }
                } closed: {
                    if model.isPanelOpen { model.endPanelSession() }
                })
        } label: {
            StatusMark(model: model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Close") { NSApplication.shared.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}

/// The menu bar icon. macOS draws its highlight while the panel is open.
private struct StatusMark: View {
    let model: MixerModel

    private var detail: String {
        model.outputMuted ? String(localized: "Output muted. \(model.statusDetail)") : model.statusDetail
    }

    var body: some View {
        // Muted comes first: nothing is audible, so whether levels apply doesn't matter right now.
        Image(nsImage: model.outputMuted ? MenuBarMark.muted
              : model.statusIsNotApplying ? MenuBarMark.paused : MenuBarMark.active)
            .help(String(localized: "Damper — \(detail)"))
            .accessibilityLabel("Damper")
            .accessibilityValue(detail)
    }
}

/// Reports when the panel opens and closes. Its window stays around between openings, so
/// SwiftUI's appear and disappear events don't track this. The panel closes when it stops being key.
private struct PanelWindowObserver: NSViewRepresentable {
    let opened: (NSWindow) -> Void
    let closed: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.opened = opened; view.closed = closed
    }

    final class ObserverView: NSView {
        var opened: (NSWindow) -> Void = { _ in }
        var closed: () -> Void = {}
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, let window = self.window { self.opened(window) } }
            })
            tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed() }
            })
            if window.isKeyWindow { opened(window) }
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = DamperApp.model
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var systemSettingsWatch: Task<Void, Never>?
    private nonisolated static let systemSettingsID = "com.apple.systempreferences"
    private var lastStatusAnnouncement: String?
    private var lastOutputError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        _ = AppUpdater.shared
        observeModel()
        watchSystemSettings()
        if model.shouldShowWelcome { showWelcome() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if model.isPanelOpen { model.endPanelSession() }
        model.stop()
        model.drainAudioTeardown()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLoginItemStatus()
        Task { await model.refreshAccessPermission() }
    }
    /// There is no public way to open the menu bar panel from code, so opening the app again shows
    /// Settings, which also helps when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
    }
    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: MixerSettings(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Damper Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func showWelcome() {
        model.noteWelcomeShown()
        let host = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in self?.welcomeWindow?.close() })
        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "Welcome to Damper")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        welcomeWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    /// Audio access is switched off in System Settings, so that is the one time worth watching for
    /// it. Nothing runs while another app is frontmost, which keeps this free when idle.
    private func watchSystemSettings() {
        systemSettingsChanged(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsID)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The short-lived permission check reports an activation with no bundle ID, and opening
            // the panel can activate this app. Neither means the user left System Settings.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            let isSystemSettings = id == Self.systemSettingsID
            MainActor.assumeIsolated { self?.systemSettingsChanged(frontmost: isSystemSettings) }
        }
    }
    private func systemSettingsChanged(frontmost: Bool) {
        let wasWatching = systemSettingsWatch != nil
        systemSettingsWatch?.cancel(); systemSettingsWatch = nil
        if frontmost {
            systemSettingsWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.model.refreshAccessPermission()
                }
            }
        } else if wasWatching {
            Task { await model.refreshAccessPermission() }
        }
    }
    /// Releases the closed window's views. Not during the close itself.
    func windowWillClose(_ notification: Notification) {
        model.clearLoginError()
        let closed = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            guard let self else { return }
            if closed === self.settingsWindow { self.settingsWindow = nil }
            if closed === self.welcomeWindow { self.welcomeWindow = nil }
        }
    }
    /// Runs even with the panel closed, when failures matter most, so announcements live here
    /// rather than in a view that may not be updating.
    private func observeModel() {
        withObservationTracking { announceChanges() } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }
    private func announceChanges() {
        let announcement = model.statusAnnouncement
        if announcement != lastStatusAnnouncement {
            lastStatusAnnouncement = announcement
            if let announcement { VoiceOver.announce(announcement) }
        }
        let outputError = model.outputError
        if outputError != lastOutputError {
            lastOutputError = outputError
            if let outputError { VoiceOver.announce(outputError) }
        }
    }
}
