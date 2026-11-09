import AppKit
import Foundation
import Observation
import ServiceManagement

public enum MixerState: Equatable {
    case needsAccess, accessDenied, waitingForAudio, ready, paused
    case failed(String)
}

public struct MixerApplication: Identifiable {
    public let id: String
    public let name: String
    public let icon: NSImage?
    public let volume: Double
    public let muted: Bool
    public let isAdjustable: Bool
    /// Text for the row. Nil when the controls stay, or when one notice covers every row.
    public let unavailableReason: String?
    /// The technical cause behind a failed row, for a tooltip rather than the row itself.
    public let unavailableDetail: String?
    public let isApplied: Bool
    public let canRetry: Bool
    public let canIgnore: Bool
    /// False for a row kept only because the panel is open after its app left.
    public let isLive: Bool
}

public struct SavedApplication: Identifiable {
    public let id: String
    public let name: String
    public let icon: NSImage?
    public let adjustment: AppAdjustment
}

/// The login item operations the model uses, so tests never query the real service.
@MainActor
protocol LoginItemControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemControlling {}

@MainActor @Observable
public final class MixerModel {
    public private(set) var state: MixerState = .needsAccess
    private(set) var isRequestingAccess = false
    public private(set) var outputs: [AudioOutputSnapshot] = []
    public private(set) var defaultOutputID: UInt32?
    public private(set) var outputError: String?
    /// The technical cause behind `outputError`, for a tooltip rather than the panel itself.
    public private(set) var outputErrorDetail: String?
    public private(set) var loginError: String?
    /// Why the current output cannot run app levels at all, with or without clients.
    public private(set) var outputUnsupportedReason: String?
    public private(set) var openAtLogin = false
    public private(set) var loginItemNeedsApproval = false
    public private(set) var isPanelOpen = false
    public private(set) var savedAdjustments: [String: AppAdjustment]
    private var clients: [String: AudioClientSnapshot] = [:]
    @ObservationIgnored private(set) var previousClients: [String: AudioClientSnapshot] = [:]
    @ObservationIgnored private(set) var lastActivity: [String: Date] = [:]
    @ObservationIgnored private(set) var lastStart: [String: Date] = [:]
    private var frozenIDs: [String] = []
    @ObservationIgnored private let backend: any AudioBackend
    @ObservationIgnored private let store: PreferenceStore
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let permission: any AudioAccessPermissionProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var monitoringActive = false
    @ObservationIgnored private var outputDragDeviceID: UInt32? {
        didSet {
            guard outputDragDeviceID == nil, oldValue != nil else { return }
            outputDragVolume = nil
            // The backend may already have reported the final level during the drag, and it
            // doesn't repeat an unchanged one.
            if outputs != reportedOutputs { outputs = reportedOutputs }
        }
    }
    /// The level under the user's pointer. It outranks a snapshot read before the latest write.
    @ObservationIgnored private var outputDragVolume: Double?
    @ObservationIgnored private var reportedOutputs: [AudioOutputSnapshot] = []
    @ObservationIgnored private var levelsRequested = false
    @ObservationIgnored private var activationGeneration: UInt64 = 0
    @ObservationIgnored private var latestPermissionCheck: UInt64 = 0
    @ObservationIgnored private var isPromptingForAccess = false
    private var audioAccessState: AudioAccessState = .notRequested
    private static let recentActivityRetention: TimeInterval = 30
    /// Short so quit can't hang on a stuck HAL call. The taps and aggregates are private to this
    /// process, so coreaudiod removes any that teardown hasn't reached when it exits.
    private static let quitDrainTimeout: TimeInterval = 0.5
    /// Above this the slider counts as full, so stopping just short of the end doesn't leave an
    /// app processed for good. The band stays narrow because every value in it plays at full level.
    private static let fullLevelSnapThreshold = 0.98

    public convenience init(backend: any AudioBackend) {
        self.init(backend: backend, store: PreferenceStore(), permission: SystemAudioAccessPermission())
    }

    init(backend: any AudioBackend, store: PreferenceStore, loginItem: any LoginItemControlling = SMAppService.mainApp,
         permission: any AudioAccessPermissionProviding, now: @escaping () -> Date = Date.init) {
        self.backend = backend; self.store = store; self.loginItem = loginItem; self.permission = permission; self.now = now
        savedAdjustments = store.apps
    }

    var isApplyingLevels: Bool { state == .ready }
    public var currentOutput: AudioOutputSnapshot? { outputs.first { $0.id == defaultOutputID } }
    public var outputVolume: Double? { currentOutput?.volume }
    public var outputMuted: Bool { currentOutput?.muted ?? false }
    public var canMuteOutput: Bool { currentOutput?.muted != nil }
    /// Shown in place of the output slider. Audio over HDMI and DisplayPort usually has no volume
    /// control macOS can use, so the connected display, TV or receiver has to change it.
    public var outputVolumeUnavailableText: String? {
        guard let output = currentOutput, output.volume == nil else { return nil }
        return output.identity == .display
            ? String(localized: "macOS can’t change the volume over HDMI or DisplayPort. Use the connected device’s controls.")
            : String(localized: "Volume control isn’t available for this output.")
    }
    /// A running app the access check can listen to. Ignored apps are left out of it.
    var hasRunningSource: Bool {
        clients.values.contains { $0.isRunningOutput && savedAdjustments[$0.id]?.ignored != true }
    }
    /// macOS reports that the app has no audio access, in a state that would otherwise look normal.
    public var needsAudioAccess: Bool {
        switch state {
        case .needsAccess: accessPermission == .notAsked || accessPermission == .denied
        case .waitingForAudio: accessPermission == .notAsked
        case .ready, .paused, .failed, .accessDenied: false
        }
    }
    /// Without the permission check, access is requested only once an app plays, so until then
    /// setup has nothing else to show.
    public var showsFirstSoundHint: Bool {
        state == .waitingForAudio && !store.hasVerifiedAccess && !hasRunningSource && accessPermission == .unavailable
    }
    public var shouldShowWelcome: Bool { !store.welcomeShown }
    public func noteWelcomeShown() { store.noteWelcomeShown() }
    /// What macOS reports for audio access. Levels still start only from real audio, but a report
    /// that access was lost stops them.
    public private(set) var accessPermission: AudioAccessPermission = .unavailable
    public func refreshAccessPermission() async {
        latestPermissionCheck &+= 1
        let check = latestPermissionCheck
        // Checks can overlap, and one that began before a change must not undo it.
        guard let answer = await permission.fresh(), check == latestPermissionCheck else { return }
        permissionReported(answer)
    }
    /// A tap without access may hand back silence while still muting its app, so losing access
    /// stops processing rather than risk that. Getting it back resumes, as Try Again would.
    private func permissionReported(_ current: AudioAccessPermission) {
        let previous = accessPermission
        guard previous != current else { return }
        accessPermission = current
        let lost = current == .denied || (previous == .allowed && current == .notAsked)
        if lost && levelsRequested {
            levelsRequested = false; activationGeneration &+= 1; isRequestingAccess = false
            try? backend.setProcessingEnabled(false)
            backend.accessWasLost()
            state = .accessDenied
        } else if current == .allowed && state == .accessDenied {
            Task { await enableAppLevels() }
        }
    }
    /// True when access is known to be on. macOS's answer wins, because real audio earlier in this
    /// session says nothing once the permission changes. Without that answer it is the only proof.
    public var isAccessConfirmed: Bool {
        accessPermission == .unavailable ? audioAccessState == .verified : accessPermission == .allowed
    }
    /// Without the permission check, this only records that macOS was asked.
    public private(set) var hasPromptedForAccess = false
    /// `answered` runs once macOS has answered. Without the permission check it runs straight away.
    public func promptForAccess(answered: @escaping @MainActor () -> Void = {}) {
        guard !isPromptingForAccess, accessPermission != .unavailable || !hasPromptedForAccess else { return }
        hasPromptedForAccess = true
        isPromptingForAccess = true
        permission.request { [weak self] answer in
            guard let self else { return }
            self.isPromptingForAccess = false
            if answer == .unavailable {
                self.backend.promptForAccess()
            } else {
                self.latestPermissionCheck &+= 1
                self.permissionReported(answer)
            }
            answered()
        }
    }
    /// An app is playing during setup and access still hasn't been confirmed, which is what a
    /// decline looks like. Once access has worked, an ordinary launch has nothing to explain.
    public var showsAccessHelp: Bool {
        state == .waitingForAudio && !store.hasVerifiedAccess && hasRunningSource && accessPermission == .unavailable
    }
    /// A running app's saved level isn't reaching it while levels are on, so it may be louder
    /// than the panel suggests. A pipeline that is still starting doesn't count.
    var hasUnappliedApplications: Bool {
        state == .ready && clients.values.contains { client in
            savedAdjustments[client.id]?.needsProcessing == true && client.isRunningOutput &&
                !client.isAdjustmentApplied && !client.isAdjustmentPending
        }
    }

    /// The status item's one line of state, also its VoiceOver value.
    public var statusDetail: String {
        if needsAudioAccess {
            return accessPermission == .denied ? String(localized: "Audio access off") : String(localized: "Audio access needed")
        }
        return switch state {
        case .needsAccess: String(localized: "App levels off")
        case .paused: String(localized: "App levels paused")
        case .failed: String(localized: "App levels stopped")
        case .accessDenied: String(localized: "Audio access off")
        case .waitingForAudio:
            outputUnsupportedReason != nil ? unavailableDetail : String(localized: "App levels on, waiting for sound")
        case .ready:
            outputUnsupportedReason != nil ? unavailableDetail
                : hasUnappliedApplications ? String(localized: "Some app levels aren’t applied")
                : String(localized: "App levels on")
        }
    }
    private var unavailableDetail: String {
        currentOutput == nil ? String(localized: "App levels unavailable without an output")
            : String(localized: "App levels unavailable on this output")
    }
    /// True when saved levels may not be applying, so sound may be louder than the panel suggests.
    public var statusIsNotApplying: Bool {
        switch state {
        case .needsAccess: needsAudioAccess
        case .paused, .failed, .accessDenied: true
        case .ready, .waitingForAudio: needsAudioAccess || outputUnsupportedReason != nil || hasUnappliedApplications
        }
    }
    /// What VoiceOver says when sound may have become louder without the user choosing that.
    /// A chosen pause and ordinary waiting stay quiet.
    public var statusAnnouncement: String? {
        switch state {
        case .needsAccess, .paused: nil
        case .failed:
            hasSavedMute ? String(localized: "App levels stopped. Apps play without your adjustments, so muted apps can be heard.")
                : String(localized: "App levels stopped. Apps play without your adjustments.")
        case .accessDenied:
            hasSavedMute ? String(localized: "Audio access is off. Apps play without your adjustments, so muted apps can be heard.")
                : String(localized: "Audio access is off. Apps play without your adjustments.")
        case .ready, .waitingForAudio: statusIsNotApplying ? statusDetail : nil
        }
    }
    private var hasSavedMute: Bool { savedAdjustments.values.contains { $0.muted && !$0.ignored } }

    public func outputIcon(for output: AudioOutputSnapshot) -> NSImage? {
        guard let url = output.iconURL else { return nil }
        let key = "output:\(output.uid):\(url.path)"
        if let cached = icons[key] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        icons[key] = image
        return image
    }

    public var applications: [MixerApplication] {
        (isPanelOpen ? frozenIDs : sortedEligibleIDs()).compactMap { id in
            guard savedAdjustments[id]?.ignored != true, let client = clients[id] ?? previousClients[id] else { return nil }
            let preference = savedAdjustments[id] ?? AppAdjustment()
            let live = clients[id] != nil
            let canEdit = live && client.isControllable && (state == .waitingForAudio || state == .needsAccess ||
                (state == .ready && (client.isAdjustmentApplied || !client.isRunningOutput || client.isAdjustmentPending)))
            let failed = live && client.canRetry
            return MixerApplication(id: id, name: client.name, icon: icon(for: client), volume: preference.volume,
                muted: preference.muted, isAdjustable: canEdit,
                unavailableReason: rowReason(client, live: live, failed: failed, canEdit: canEdit),
                unavailableDetail: failed ? client.unavailableReason : nil,
                isApplied: live && isApplyingLevels && client.isAdjustmentApplied,
                canRetry: failed, canIgnore: client.hasStableIdentity, isLive: live)
        }
    }

    public var savedApplications: [SavedApplication] {
        savedAdjustments.map { id, adjustment in
            let client = clients[id] ?? previousClients[id]
            let appURL = client?.applicationURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = client?.name ?? appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? appURL?.deletingPathExtension().lastPathComponent ?? id
            return SavedApplication(id: id, name: name, icon: icon(id: id, url: appURL), adjustment: adjustment)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func start() {
        guard !started else { return }; started = true
        accessPermission = permission.current
        backend.onSnapshot = { [weak self] in self?.receive($0) }
        backend.onFailure = { [weak self] message in
            guard let self, self.levelsRequested else { return }
            self.fail(message)
        }
        do {
            for (id, value) in savedAdjustments { backend.setAdjustment(value, for: id) }
            try backend.startMonitoring()
            monitoringActive = true
            if store.hasEnabled {
                if store.paused { state = .paused }
                else {
                    state = .waitingForAudio
                    let generation = activationGeneration
                    Task { [weak self] in
                        guard let self, self.started, self.activationGeneration == generation,
                              self.state == .waitingForAudio else { return }
                        await self.enableAppLevels()
                    }
                }
            }
        } catch {
            if error as? AudioBackendError == .permissionDenied {
                try? backend.setProcessingEnabled(false); state = .accessDenied
            } else { fail(error.localizedDescription) }
        }
        refreshLoginItemStatus()
    }

    public func stop() {
        levelsRequested = false; activationGeneration &+= 1; isRequestingAccess = false
        store.flush(); backend.stop(); started = false; monitoringActive = false; outputDragDeviceID = nil
    }
    /// Gives queued audio teardown a bounded chance to finish before the process exits.
    public func drainAudioTeardown() { backend.drain(timeout: Self.quitDrainTimeout) }
    public func beginPanelSession() { isPanelOpen = true; frozenIDs = sortedEligibleIDs() }
    public func endPanelSession() {
        isPanelOpen = false; frozenIDs = []; outputDragDeviceID = nil
        clearOutputError()
        store.flush()
        finishedAdjusting()
    }
    /// Access is requested the first time it is needed: once a change is finished, rather than
    /// mid-drag, because the system prompt closes the panel. Levels saved before then apply afterwards.
    public func finishedAdjusting() {
        guard started, state == .needsAccess, savedAdjustments.values.contains(where: \.needsProcessing) else { return }
        Task { await enableAppLevels() }
    }

    /// Try Again from the access notice. It goes by macOS's answer as of now: still denied changes
    /// nothing, and never asked can show the system prompt, which starts levels if allowed.
    public func retryAccess() async {
        await refreshAccessPermission()
        switch accessPermission {
        case .denied: break
        case .notAsked: promptForAccess()
        case .allowed, .unavailable:
            // Before levels were ever turned on, access alone doesn't start them. A saved level does.
            if state == .needsAccess { finishedAdjusting() } else { await enableAppLevels() }
        }
    }

    public func enableAppLevels() async {
        if accessPermission == .denied {
            // Remembered, so the saved levels start on a later launch once access is on.
            levelsRequested = false; state = .accessDenied
            store.setActivation(hasEnabled: true, paused: false)
            return
        }
        guard !isRequestingAccess else { return }; isRequestingAccess = true
        activationGeneration &+= 1
        let generation = activationGeneration
        levelsRequested = true
        state = .waitingForAudio
        defer { if activationGeneration == generation { isRequestingAccess = false } }
        do {
            if started, !monitoringActive {
                try backend.startMonitoring()
                monitoringActive = true
                // Recovering discovery must not ask for access before it is needed, or undo a saved pause.
                if !store.hasEnabled || store.paused {
                    levelsRequested = false
                    state = store.hasEnabled ? .paused : .needsAccess
                    return
                }
            }
            try await backend.requestAccess()
            guard generation == activationGeneration, levelsRequested, started else { return }
            try backend.setProcessingEnabled(true)
            guard generation == activationGeneration, levelsRequested, started else { return }
            state = audioAccessState == .verified ? .ready : .waitingForAudio
            store.setActivation(hasEnabled: true, paused: false)
        } catch {
            guard generation == activationGeneration, levelsRequested, started else { return }
            if error as? AudioBackendError == .permissionDenied {
                levelsRequested = false
                try? backend.setProcessingEnabled(false); state = .accessDenied
            } else { fail(error.localizedDescription) }
        }
    }

    public func pauseAppLevels() {
        levelsRequested = false; activationGeneration &+= 1; isRequestingAccess = false
        try? backend.setProcessingEnabled(false)
        state = .paused; store.setActivation(hasEnabled: true, paused: true)
    }

    public func setVolume(_ volume: Double, for id: String) {
        guard volume.isFinite, canAdjust(id) else { return }
        var value = savedAdjustments[id] ?? AppAdjustment()
        value.volume = volume >= Self.fullLevelSnapThreshold ? 1 : volume
        value.muted = false; save(value, for: id, coalescing: true)
    }
    public func toggleMute(for id: String) {
        guard canAdjust(id) else { return }
        var value = savedAdjustments[id] ?? AppAdjustment(); value.muted.toggle(); save(value, for: id)
        finishedAdjusting()
    }
    public func resetVolume(for id: String) { guard canAdjust(id) else { return }; save(AppAdjustment(), for: id) }
    public func ignoreApplication(_ id: String) {
        guard (clients[id] ?? previousClients[id])?.hasStableIdentity != false else { return }
        save(AppAdjustment(ignored: true), for: id)
    }
    /// Retries a row whose processing failed. Its saved level is sent directly because the row
    /// has no controls, so `save` paths gated by `canAdjust` would refuse it.
    public func retryApplication(_ id: String) {
        guard clients[id]?.canRetry == true else { return }
        backend.setAdjustment(savedAdjustments[id] ?? AppAdjustment(), for: id)
    }
    public func removeSavedApplication(_ id: String) {
        backend.removeAdjustment(for: id); store.remove(id); savedAdjustments = store.apps
    }
    public func selectOutput(_ id: UInt32) { perform(failure: String(localized: "Couldn’t switch to that output.")) { try backend.selectOutput(id) } }
    /// Holds output volume writes to the current device for a whole drag, so a thumb position
    /// meant for one device cannot land on the device that replaces it.
    public func setOutputVolumeDragging(_ dragging: Bool) { outputDragDeviceID = dragging ? defaultOutputID : nil }
    public func setOutputVolume(_ volume: Double) {
        guard volume.isFinite, let output = currentOutput, outputDragDeviceID ?? output.id == output.id else { return }
        let level = min(1, max(0, volume))
        perform(failure: String(localized: "Couldn’t change this output’s volume.")) {
            try backend.setOutputVolume(level, for: output.id)
            if output.muted == true { try backend.setOutputMuted(false, for: output.id) }
            // The slider follows the pointer now, rather than waiting for the backend to report back.
            if outputDragDeviceID == output.id { outputDragVolume = level }
            noteOutputWrite(output.id) { $0.withLevels(volume: level, muted: $0.muted == nil ? nil : false) }
        }
    }
    public func toggleOutputMute() {
        guard let output = currentOutput, let muted = output.muted else { return }
        perform(failure: String(localized: "Couldn’t change this output’s mute setting.")) {
            try backend.setOutputMuted(!muted, for: output.id)
            noteOutputWrite(output.id) { $0.withLevels(volume: $0.volume, muted: !muted) }
        }
    }
    /// The backend only reports a read-back that differs from what it wrote, so a write that lands
    /// exactly is recorded here as shown and as reported. Otherwise the end of a drag would put
    /// back the level from before it.
    private func noteOutputWrite(_ id: UInt32, _ change: (AudioOutputSnapshot) -> AudioOutputSnapshot) {
        outputs = outputs.map { $0.id == id ? change($0) : $0 }
        reportedOutputs = reportedOutputs.map { $0.id == id ? change($0) : $0 }
    }
    public func setOpenAtLogin(_ enabled: Bool) {
        loginError = nil
        do { if enabled { try loginItem.register() } else { try loginItem.unregister() } }
        catch { loginError = error.localizedDescription }
        refreshLoginItemStatus()
    }
    public func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }
    public func clearLoginError() { loginError = nil }
    public func openPrivacySettings() { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") }
    public func openSoundSettings() { openSystemSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
    public func openMenuBarSettings() { openSystemSettings("x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") }
    /// These pane links are undocumented, and an unknown one may still open Settings and report
    /// success, so the audio access buttons also name the path in their tooltip.
    private func openSystemSettings(_ link: String) {
        if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    private func canAdjust(_ id: String) -> Bool { applications.first { $0.id == id }?.isAdjustable == true }
    private func rowReason(_ client: AudioClientSnapshot, live: Bool, failed: Bool, canEdit: Bool) -> String? {
        if outputUnsupportedReason != nil { return nil }
        if !live {
            return savedAdjustments[client.id] == nil ? String(localized: "No longer active.")
                : String(localized: "Not running. Your saved level is kept.")
        }
        if failed { return String(localized: "Couldn’t apply your saved level. This app stays at its own volume.") }
        return !client.isControllable || (isApplyingLevels && !canEdit) ? client.unavailableReason : nil
    }
    private func save(_ adjustment: AppAdjustment, for id: String, coalescing: Bool = false) {
        backend.setAdjustment(adjustment, for: id)
        store.save(adjustment, for: id, coalescing: coalescing)
        savedAdjustments = store.apps
    }
    public func refreshLoginItemStatus() {
        let status = loginItem.status
        loginItemNeedsApproval = status == .requiresApproval
        openAtLogin = status == .enabled || loginItemNeedsApproval
    }
    private func perform(failure: String, _ action: () throws -> Void) {
        clearOutputError()
        do { try action() } catch { outputError = failure; outputErrorDetail = error.localizedDescription }
    }
    private func clearOutputError() {
        if outputError != nil { outputError = nil; outputErrorDetail = nil }
    }
    private func fail(_ message: String) {
        levelsRequested = false
        try? backend.setProcessingEnabled(false); state = .failed(message)
    }
    private func receive(_ snapshot: AudioSnapshot) {
        audioAccessState = snapshot.accessState
        if snapshot.accessState == .verified { store.noteAccessVerified() }
        if levelsRequested {
            switch snapshot.accessState {
            case .verified: state = .ready
            case .notRequested, .waitingForAudio: state = .waitingForAudio
            case .denied:
                levelsRequested = false
                try? backend.setProcessingEnabled(false)
                state = .accessDenied
            }
        }
        let time = now(); previousClients.merge(clients) { _, new in new }
        let incoming = Dictionary(snapshot.clients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for client in snapshot.clients {
            if client.isRunningOutput {
                if clients[client.id]?.isRunningOutput != true { lastStart[client.id] = time }
                lastActivity[client.id] = time
            } else if clients[client.id]?.isRunningOutput == true { lastActivity[client.id] = time }
        }
        // Unchanged values must not redraw the panel, which matters during a slider drag.
        if clients != incoming { clients = incoming }
        reportedOutputs = snapshot.outputs
        let reported = snapshot.outputs.map { output in
            guard output.id == outputDragDeviceID, let outputDragVolume else { return output }
            return output.withLevels(volume: outputDragVolume, muted: output.muted)
        }
        if outputs != reported { outputs = reported }
        if defaultOutputID != snapshot.defaultOutputID { defaultOutputID = snapshot.defaultOutputID }
        if outputUnsupportedReason != snapshot.outputUnsupportedReason { outputUnsupportedReason = snapshot.outputUnsupportedReason }
        if isPanelOpen {
            for id in sortedEligibleIDs() where !frozenIDs.contains(id) { frozenIDs.append(id) }
        }
        let keep = { (id: String) in incoming[id] != nil || self.frozenIDs.contains(id) || self.savedAdjustments[id] != nil }
        previousClients = previousClients.filter { keep($0.key) }
        lastStart = lastStart.filter { keep($0.key) }
        lastActivity = lastActivity.filter { keep($0.key) || time.timeIntervalSince($0.value) < Self.recentActivityRetention }
    }
    private func sortedEligibleIDs() -> [String] {
        let time = now()
        return clients.values.filter { client in
            let saved = savedAdjustments[client.id] ?? AppAdjustment()
            return !saved.ignored && (client.isRunningOutput || saved.needsProcessing || lastActivity[client.id].map { time.timeIntervalSince($0) < Self.recentActivityRetention } == true)
        }.sorted { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            let at = (a.isRunningOutput ? lastStart[a.id] : lastActivity[a.id]) ?? .distantPast
            let bt = (b.isRunningOutput ? lastStart[b.id] : lastActivity[b.id]) ?? .distantPast
            return at == bt ? a.name.localizedStandardCompare(b.name) == .orderedAscending : at > bt
        }.map(\.id)
    }
    private func icon(for client: AudioClientSnapshot) -> NSImage? {
        if let cached = icons[client.id] { return cached }
        return icon(id: client.id, url: client.applicationURL ?? client.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
    }
    private func icon(id: String, url: URL?) -> NSImage? {
        if let cached = icons[id] { return cached }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path); icons[id] = image; return image
    }
}
