import Accessibility
import AppKit
import DamperCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - List

/// App rows in model order, in one scroll view so a seventh app doesn't rebuild the rows under
/// a drag. The viewport is measured from the first six rows, so the panel keeps an intrinsic
/// height, and a part of the next row shows that the list continues. Scroll indicators stay off
/// because a legacy scroller would narrow the rows out of line with the output slider.
struct AppList: View {
    let model: MixerModel
    let apps: [MixerApplication]
    /// The height left on screen for the list.
    let maxHeight: CGFloat
    @State private var rowHeights: [String: CGFloat] = [:]

    private static let spacing: CGFloat = 8
    private static let estimatedRowHeight = PanelMetrics.iconSize + 2 + PanelMetrics.muteTarget

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(apps) { app in
                    AppRow(model: model, app: app)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            guard rowHeights[app.id] != height else { return }
                            rowHeights[app.id] = height
                        }
                }
            }
            .padding(.horizontal, PanelMetrics.inset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(naturalHeight <= viewportHeight)
        .scrollIndicators(.never)
        .frame(height: viewportHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apps")
    }

    private var naturalHeight: CGFloat {
        apps.reduce(0) { $0 + (rowHeights[$1.id] ?? Self.estimatedRowHeight) } + Self.spacing * CGFloat(apps.count - 1)
    }

    private var viewportHeight: CGFloat {
        AppListLayout.viewportHeight(rowHeights: apps.map { rowHeights[$0.id] ?? Self.estimatedRowHeight },
                                     spacing: Self.spacing, peek: PanelMetrics.iconSize / 2,
                                     maxVisibleRows: PanelMetrics.maxVisibleRows, limit: maxHeight)
    }
}

// MARK: - Row

/// Two lines: icon and name, then the level slider and mute button under the name.
struct AppRow: View {
    let model: MixerModel
    let app: MixerApplication

    private var hasAdjustment: Bool { app.volume < 1 || app.muted }
    private var canReset: Bool { app.isAdjustable && hasAdjustment }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PanelMetrics.iconGap) {
                AppIcon(image: app.icon, size: PanelMetrics.iconSize)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(app.name)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            Group {
                // With no reason, the notice above the list explains why controls are disabled.
                if let caption = app.unavailableReason {
                    captionRow(caption)
                } else {
                    controls
                }
            }
            .padding(.leading, PanelMetrics.iconSize + PanelMetrics.iconGap)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset Volume") { model.resetVolume(for: app.id) }
                .disabled(!canReset)
            if app.canIgnore {
                if hasAdjustment {
                    Button { model.ignoreApplication(app.id) } label: {
                        Text("Ignore \(app.name)")
                        Text("Returns to its own volume and forgets its level")
                    }
                } else {
                    Button("Ignore \(app.name)") { model.ignoreApplication(app.id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
        .onChange(of: app.unavailableReason) { _, caption in
            if model.isPanelOpen, let caption { VoiceOver.announce(String(localized: "\(app.name): \(caption)")) }
        }
    }

    /// The caption replaces the controls, so it carries the row's one action.
    private func captionRow(_ caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(app.unavailableDetail ?? caption)
                .modifier(RowActions(model: model, app: app, canReset: canReset))
            if app.canRetry {
                Button("Try Again") { model.retryApplication(app.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Try Again for \(app.name)")
            } else if app.canIgnore && app.isLive {
                Button("Ignore") { model.ignoreApplication(app.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Ignore \(app.name)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: PanelMetrics.muteTarget, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Slider(value: volume, in: 0...1) {
                Text("\(app.name) volume")
            } onEditingChanged: { editing in
                if !editing { model.finishedAdjusting() }
            }
            .labelsHidden()
            // A muted app keeps a live slider at its saved level; dragging unmutes it.
            .tint(app.muted ? Color.secondary : nil)
            .accessibilityValue(LevelText.app(volume: app.volume, muted: app.muted, applied: app.isApplied))
            .modifier(RowActions(model: model, app: app, canReset: canReset))

            MuteButton(muteLabel: "Mute \(app.name)", unmuteLabel: "Unmute \(app.name)", muted: app.muted, level: app.volume) {
                model.toggleMute(for: app.id)
            }
        }
        .disabled(!app.isAdjustable)
    }

    private var volume: Binding<Double> {
        let id = app.id, saved = app.volume
        return Binding(
            get: { model.savedAdjustments[id]?.volume ?? saved },
            set: { model.setVolume($0, for: id) }
        )
    }
}

/// VoiceOver equivalents of the row's context menu.
private struct RowActions: ViewModifier {
    let model: MixerModel
    let app: MixerApplication
    let canReset: Bool

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if canReset {
                Button("Reset Volume") { model.resetVolume(for: app.id) }
            }
            if app.canIgnore {
                Button("Ignore \(app.name)") { model.ignoreApplication(app.id) }
            }
        }
    }
}

// MARK: - Shared pieces

/// Borderless speaker toggle. The glyph shows the saved level; a slash means muted.
struct MuteButton: View {
    let muteLabel: LocalizedStringKey
    let unmuteLabel: LocalizedStringKey
    let muted: Bool
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: muted ? nil : level)
                .font(.body)
                .frame(width: PanelMetrics.muteTarget, height: PanelMetrics.muteTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(muted ? unmuteLabel : muteLabel)
        .accessibilityLabel(muteLabel)
        .accessibilityValue(muted ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    var body: some View {
        Image(nsImage: image ?? Self.genericIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum VoiceOver {
    /// High priority because plain announcements can be skipped by later speech.
    @MainActor static func announce(_ text: String) {
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(message).post()
    }
}
