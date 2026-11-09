import Foundation
import os

/// The part of `UserDefaults` the store uses, so tests can keep preferences in memory.
protocol PreferenceStorage {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStorage {}

@MainActor
final class PreferenceStore {
    private let defaults: any PreferenceStorage
    private let key = "damper.preferences.v1"
    private static let saveCoalescingDelay: Duration = .milliseconds(150)
    private static let logger = Logger(subsystem: "io.github.tadassuksteris.damper", category: "preferences")
    private struct Document: Codable {
        var apps: [String: AppAdjustment] = [:]
        var hasEnabled = false
        var paused = false
        var hasVerifiedAccess = false
        var welcomeShown = false

        init() {}

        /// A missing field takes its default, so adding a field cannot lose saved levels.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            apps = try container.decodeIfPresent([String: AppAdjustment].self, forKey: .apps) ?? [:]
            hasEnabled = try container.decodeIfPresent(Bool.self, forKey: .hasEnabled) ?? false
            paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            hasVerifiedAccess = try container.decodeIfPresent(Bool.self, forKey: .hasVerifiedAccess) ?? false
            welcomeShown = try container.decodeIfPresent(Bool.self, forKey: .welcomeShown) ?? false
        }
    }
    private var document: Document
    private var pendingWrite: Task<Void, Never>?

    init(defaults: any PreferenceStorage = UserDefaults.standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key)
        do { document = try saved.map { try JSONDecoder().decode(Document.self, from: $0) } ?? Document() }
        catch {
            // Starting over overwrites the document, so keep a copy for anyone recovering their levels.
            Self.logger.error("Saved preferences could not be read: \(error.localizedDescription, privacy: .public)")
            defaults.set(saved, forKey: key + ".unreadable")
            document = Document()
        }
    }

    var apps: [String: AppAdjustment] { document.apps }
    var hasEnabled: Bool { document.hasEnabled }
    var paused: Bool { document.paused }
    var hasVerifiedAccess: Bool { document.hasVerifiedAccess }
    var welcomeShown: Bool { document.welcomeShown }

    func save(_ value: AppAdjustment, for id: String, coalescing: Bool = false) {
        if value == AppAdjustment() { document.apps.removeValue(forKey: id) }
        else { document.apps[id] = value }
        if coalescing {
            pendingWrite?.cancel()
            pendingWrite = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.saveCoalescingDelay) } catch { return }
                self?.flush()
            }
        } else { flush() }
    }
    func remove(_ id: String) { document.apps.removeValue(forKey: id); flush() }
    func setActivation(hasEnabled: Bool, paused: Bool) {
        document.hasEnabled = hasEnabled; document.paused = paused; flush()
    }
    func noteAccessVerified() {
        guard !document.hasVerifiedAccess else { return }
        document.hasVerifiedAccess = true; flush()
    }
    func noteWelcomeShown() { document.welcomeShown = true; flush() }
    func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: key)
    }
}
