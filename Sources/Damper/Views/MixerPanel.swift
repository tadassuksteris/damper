import AppKit
import DamperCore
import Observation
import SwiftUI

/// The content of the menu bar panel. macOS draws the surface around it.
struct MixerPanel: View {
    let model: MixerModel
    let layout: PanelLayout
    let openSettings: () -> Void
    let quit: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Where the app list starts, so only the list gives way on a short display.
    @State private var listTop: CGFloat = 0

    private static let bottomPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.top, 10)
            OutputSection(model: model)
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.top, 2)
            Divider()
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.vertical, 8)
            appsSection
        }
        .padding(.bottom, Self.bottomPadding)
        .frame(width: PanelMetrics.width, alignment: .leading)
        .coordinateSpace(.named(PanelMetrics.coordinateSpace))
        .onExitCommand { dismiss() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Damper")
                .font(.body.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Menu {
                switch model.state {
                case .ready, .waitingForAudio:
                    Button { model.pauseAppLevels() } label: {
                        Text("Pause App Levels")
                        Text("Apps play without your adjustments")
                    }
                    Divider()
                    Button("Audio Access Settings…") { model.openPrivacySettings() }
                    Divider()
                case .paused, .failed:
                    Button("Resume App Levels") { Task { await model.enableAppLevels() } }
                    Divider()
                case .needsAccess, .accessDenied:
                    EmptyView()
                }
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",")
                if AppUpdater.shared.isAvailable {
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                }
                Divider()
                if model.savedAdjustments.values.contains(where: \.needsProcessing) {
                    Button(action: quit) {
                        Text("Quit Damper")
                        Text("Apps play without your adjustments")
                    }
                    .keyboardShortcut("q")
                } else {
                    Button("Quit Damper", action: quit)
                        .keyboardShortcut("q")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .frame(minHeight: 28)
    }

    // MARK: Apps

    private var appsSection: some View {
        let apps = model.applications
        return VStack(alignment: .leading, spacing: 12) {
            StatusNotice(model: model)
                .padding(.horizontal, PanelMetrics.inset)
            if apps.isEmpty {
                emptyMessage
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.vertical, 10)
            } else {
                AppList(model: model, apps: apps, maxHeight: layout.availableHeight - listTop - Self.bottomPadding)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PanelMetrics.coordinateSpace)).minY } action: { top in
                        listTop = top
                    }
            }
        }
    }

    private var emptyMessage: Text {
        model.showsFirstSoundHint
            ? Text("Play any sound to finish setup. macOS may ask for access when an app first plays.")
            : Text("Apps appear here when they start audio.")
    }
}

/// The screen height the open panel may use, set as it opens.
@MainActor @Observable
final class PanelLayout {
    var availableHeight: CGFloat = .greatestFiniteMagnitude
}

enum PanelMetrics {
    static let width: CGFloat = 320
    static let inset: CGFloat = 14
    static let iconSize: CGFloat = 24
    static let iconGap: CGFloat = 10
    static let muteTarget: CGFloat = 24
    static let maxVisibleRows = 6
    /// Kept clear between the panel and the screen edge.
    static let screenMargin: CGFloat = 12
    static let coordinateSpace = "panel"
}

// MARK: - Output

private struct OutputSection: View {
    let model: MixerModel
    @State private var deviceHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.outputs.isEmpty {
                Text("No output device is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                outputDevice

                if let volume = model.outputVolume {
                    HStack(spacing: 6) {
                        Slider(value: volumeBinding(current: volume), in: 0...1) {
                            Text("Output volume")
                        } onEditingChanged: { editing in
                            model.setOutputVolumeDragging(editing)
                        }
                        .labelsHidden()
                        .tint(model.outputMuted ? Color.secondary : nil)
                        .accessibilityValue(LevelText.output(volume: volume, muted: model.outputMuted))
                        muteSlot(level: volume)
                    }
                    .padding(.leading, PanelMetrics.iconSize + PanelMetrics.iconGap)
                } else if let unavailable = model.outputVolumeUnavailableText {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(unavailable)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.canMuteOutput { muteSlot(level: 1) }
                    }
                    .padding(.leading, PanelMetrics.iconSize + PanelMetrics.iconGap)
                }
            }
            if let error = model.outputError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.outputErrorDetail ?? error)
            }
        }
    }

    private var outputDevice: some View {
        Menu {
            Picker("Output", selection: selection) {
                ForEach(model.outputs) { output in
                    Label(output.name, systemImage: output.identity.symbolName).tag(Optional(output.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Sound Settings…") { model.openSoundSettings() }
        } label: {
            deviceLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .opacity(deviceHovered ? 1 : 0)
        }
        .onHover { deviceHovered = $0 }
        .accessibilityLabel("Output")
        .accessibilityValue(model.currentOutput?.name ?? String(localized: "No output selected"))
        .accessibilityHint("Choose output device")
        .help(outputHelp)
    }

    private var outputHelp: LocalizedStringKey {
        if let name = model.currentOutput?.name { "\(name) — Choose output device" } else { "Choose output device" }
    }

    private var deviceLabel: some View {
        HStack(spacing: PanelMetrics.iconGap) {
            Group {
                if let output = model.currentOutput, !output.identity.prefersSymbol, let image = model.outputIcon(for: output) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: model.currentOutput?.identity.symbolName ?? "hifispeaker")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: PanelMetrics.iconSize, height: PanelMetrics.iconSize)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                (model.currentOutput.map { Text($0.name) } ?? Text("Choose Output"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.muteTarget, height: PanelMetrics.muteTarget)
                .accessibilityHidden(true)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func muteSlot(level: Double) -> some View {
        if model.canMuteOutput {
            MuteButton(muteLabel: "Mute Output", unmuteLabel: "Unmute Output", muted: model.outputMuted, level: level) {
                model.toggleOutputMute()
            }
        } else {
            // Keeps the slider aligned with the app rows' sliders.
            Color.clear.frame(width: PanelMetrics.muteTarget, height: PanelMetrics.muteTarget)
                .accessibilityHidden(true)
        }
    }

    private var selection: Binding<UInt32?> {
        Binding(
            get: { model.defaultOutputID },
            set: { id in if let id { model.selectOutput(id) } }
        )
    }

    private func volumeBinding(current: Double) -> Binding<Double> {
        Binding(
            get: { model.outputVolume ?? current },
            set: { value in model.setOutputVolume(value) }
        )
    }
}

// MARK: - Status notice

/// One message with at most one recovery path, shown above the app list only when something
/// needs the user. Normal use stays quiet, and a row explains its own problem.
private struct StatusNotice: View {
    let model: MixerModel

    @ViewBuilder
    var body: some View {
        switch model.state {
        case .needsAccess:
            if let reason = model.outputUnsupportedReason {
                unsupportedOutput(reason: reason)
            } else if model.accessPermission == .denied {
                accessOff
            } else if model.needsAudioAccess {
                accessNeeded
            }
        case .ready:
            if let reason = model.outputUnsupportedReason { unsupportedOutput(reason: reason) }
        case .waitingForAudio:
            if let reason = model.outputUnsupportedReason {
                unsupportedOutput(reason: reason)
            } else if model.needsAudioAccess {
                accessNeeded
            } else if model.showsAccessHelp {
                notice(symbol: "info.circle", "Waiting for audio access", detail: "Levels start once an app’s sound comes through.") {
                    Button("Open System Settings") { model.openPrivacySettings() }
                }
            }
        case .paused:
            notice(symbol: "pause.circle", "App levels are paused", detail: ownVolume) {
                retryButton("Resume")
            }
        case let .failed(detail):
            notice(symbol: "exclamationmark.triangle", "App levels stopped", detail: ownVolume) {
                retryButton("Try Again")
            }
            .help(detail)
        case .accessDenied:
            accessOff
        }
    }

    private var accessNeeded: some View {
        notice(symbol: "hand.raised", "Audio access needed", detail: "Needed to lower or mute apps. Audio is never saved or sent.") {
            Button("Allow Audio Access…") { model.promptForAccess() }
        }
    }

    private var accessOff: some View {
        notice(symbol: "hand.raised", "Audio access is off", detail: ownVolume) {
            Button("Open System Settings") { model.openPrivacySettings() }
            Button("Try Again") { Task { await model.retryAccess() } }
        }
        .help("Privacy & Security > Screen & System Audio Recording > System Audio Recording Only")
    }

    /// Only mention muted apps when the user actually has a saved mute.
    private var ownVolume: LocalizedStringKey {
        model.savedAdjustments.values.contains { $0.muted && !$0.ignored }
            ? "Apps play at their own volume, including muted ones."
            : "Apps play at their own volume."
    }

    private func unsupportedOutput(reason: String) -> some View {
        let name = model.currentOutput?.name
        return notice(symbol: "exclamationmark.triangle",
                      name.map { "App levels can’t run on \($0)" } ?? "App levels need an output",
                      detail: ownVolume) {
            EmptyView()
        }
        .help(reason)
    }

    private func notice<Actions: View>(symbol: String, _ title: LocalizedStringKey, detail: LocalizedStringKey,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
                    .controlSize(.small)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func retryButton(_ title: LocalizedStringKey) -> some View {
        Button(title) { Task { await model.enableAppLevels() } }
    }
}
