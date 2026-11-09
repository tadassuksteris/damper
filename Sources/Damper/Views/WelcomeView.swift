import AppKit
import DamperCore
import SwiftUI

/// Shown once, on first launch, because a menu bar app otherwise opens with nothing to see.
struct WelcomeView: View {
    let model: MixerModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIcon(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath), size: 48)
                Text("Damper is in your menu bar")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Click")
                Image(nsImage: MenuBarMark.active)
                    .renderingMode(.template)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityLabel("the Damper icon")
                Text("to set the volume of each app.")
            }
            AudioAccessControls(model: model)
            VStack(alignment: .leading, spacing: 6) {
                OpenAtLoginControls(model: model)
            }
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// macOS's current answer on audio access and the one thing to do about it, shared by Settings and
/// the welcome window.
struct AudioAccessControls: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isAccessConfirmed {
                Label("Audio access is on", systemImage: "checkmark.circle")
            } else if model.accessPermission == .denied {
                Label("Audio access is off", systemImage: "hand.raised")
                explanation("Turn it on to lower or mute apps.")
                Button("Open System Settings") { model.openPrivacySettings() }
                    .help("Privacy & Security > Screen & System Audio Recording > System Audio Recording Only")
            } else if model.hasPromptedForAccess && model.accessPermission == .unavailable {
                explanation("If macOS didn’t ask, you’ve already answered.")
                Button("Open System Settings") { model.openPrivacySettings() }
            } else {
                explanation("Needed to lower or mute apps. Audio is never saved or sent.")
                Button("Allow Audio Access…") {
                    // The prompt belongs to another process, and macOS doesn't return focus to this
                    // window after it, so it would end up behind whatever else is open. A window
                    // closed in the meantime stays closed.
                    let window = NSApplication.shared.keyWindow
                    model.promptForAccess {
                        guard let window, window.isVisible else { return }
                        NSApplication.shared.activate()
                        window.orderFrontRegardless()
                        window.makeKey()
                    }
                }
            }
        }
        // Each check starts a short-lived process, so this asks once. The app delegate asks again
        // while System Settings is in front and when Damper becomes active.
        .task { await model.refreshAccessPermission() }
    }

    private func explanation(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
