import AppKit
import DamperCore
import SwiftUI

/// Single-pane Settings window content. The app delegate hosts it in an ordinary `NSWindow`.
struct MixerSettings: View {
    let model: MixerModel

    private static let versionLabel =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { String(localized: "Version \($0)") }
            ?? String(localized: "Development build")

    /// Measured, because the content's height changes with the access state and the saved apps.
    @State private var contentHeight: CGFloat = 420
    private static let maxHeight: CGFloat = 640
    private static let sourceURL = URL(string: "https://github.com/tadassuksteris/damper")!

    var body: some View {
        Form {
            Section {
                AudioAccessControls(model: model)
            }

            Section {
                OpenAtLoginControls(model: model)
            } footer: {
                Text("Levels apply only while Damper is running. The start of a sound can briefly play at full level.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Don’t see the Damper icon in the menu bar?")
                        .foregroundStyle(.secondary)
                    Button("Open Menu Bar Settings") { model.openMenuBarSettings() }
                }
                if AppUpdater.shared.isAvailable { UpdateControls() }
                LabeledContent("Damper", value: Self.versionLabel)
                Link("Source on GitHub", destination: Self.sourceURL)
            }

            // Last, because it is the only section that grows. A long list then pushes nothing else
            // out of reach.
            Section {
                let saved = model.savedApplications
                if saved.isEmpty {
                    Text("Apps you adjust or ignore are listed here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(saved) { app in
                        SavedAppRow(app: app) { model.removeSavedApplication(app.id) }
                    }
                }
            } header: {
                Text("Saved Apps")
            } footer: {
                Text("Removing an app returns it to its own volume. An ignored app shows in the panel again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // The window fits its content up to the cap, with no scroll bar: "never" also covers the
        // Always Show Scroll Bars setting, which "hidden" does not. Past the cap the content scrolls,
        // and the bar follows that setting so there is a sign of more below.
        .scrollIndicators(contentHeight > Self.maxHeight ? .automatic : .never)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, height in
            contentHeight = height
        }
        .frame(width: 420, height: min(contentHeight.rounded(.up), Self.maxHeight))
    }
}

/// The Open at Login toggle and anything it needs to say, shared by Settings and the welcome window.
struct OpenAtLoginControls: View {
    let model: MixerModel

    var body: some View {
        Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
        if model.loginItemNeedsApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Damper in Login Items to finish enabling it.")
                    .foregroundStyle(.secondary)
                Button("Open Login Items Settings") { model.openLoginItemSettings() }
            }
        }
        if let error = model.loginError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UpdateControls: View {
    @State private var checksAutomatically = AppUpdater.shared.checksAutomatically

    var body: some View {
        Toggle("Check for updates automatically", isOn: $checksAutomatically)
            .onChange(of: checksAutomatically) { _, enabled in AppUpdater.shared.checksAutomatically = enabled }
        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
    }
}

private struct SavedAppRow: View {
    let app: SavedApplication
    let remove: () -> Void

    private var value: String {
        if app.adjustment.ignored { return String(localized: "Ignored") }
        if app.adjustment.muted { return String(localized: "Muted") }
        return LevelText.percent(app.adjustment.volume)
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon, size: 20)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(app.name)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Remove", action: remove)
                .controlSize(.small)
                .help(app.adjustment.ignored ? Text("Stop ignoring \(app.name)") : Text("Return \(app.name) to its own volume"))
                .accessibilityLabel("Remove \(app.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name), \(value)")
    }
}
