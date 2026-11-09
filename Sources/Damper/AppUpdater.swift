import Foundation
import Sparkle

/// In-app updates through Sparkle. Only release builds carry the public key that verifies updates,
/// so other builds never start the updater, make no network requests and show no update controls.
@MainActor
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    override private init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Sparkle shows an update from a scheduled check without taking focus, unless the app has just
    /// launched. Saying so here stops the warning it logs for apps with no Dock icon.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
