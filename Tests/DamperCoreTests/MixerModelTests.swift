import Foundation
import Observation
import ServiceManagement
import Testing
@testable import DamperCore

/// Follows `CoreAudioBackend`'s contract: discovery must run before a request, a request before
/// enabling, access only becomes verified through a later snapshot, and adjustment and
/// processing changes publish synchronously. Output writes publish later, so they don't here.
@MainActor
private final class TestBackend: AudioBackend {
    var onSnapshot: ((AudioSnapshot) -> Void)?
    var onFailure: ((String) -> Void)?
    var requested = 0
    var monitoringStarts = 0
    var monitoring = false
    var enabled = false
    var accessWasRequested = false
    var startError: AudioBackendError?
    var requestError: AudioBackendError?
    var outputFailure: AudioBackendError?
    var desired: [String: AppAdjustment] = [:]
    var adjustmentCalls: [String] = []
    var drains: [TimeInterval] = []
    var outputActions: [String] = []
    var access: AudioAccessState = .notRequested
    var lastClients: [AudioClientSnapshot] = []
    var lastOutputs: [AudioOutputSnapshot] = []
    var lastDefaultOutputID: UInt32?
    var lastUnsupportedReason: String?
    var suspendRequest = false
    var requestWaiter: CheckedContinuation<Void, Never>?

    func startMonitoring() throws {
        monitoringStarts += 1
        guard !monitoring else { publish(); return }
        if let startError { throw startError }
        monitoring = true
        publish()
    }
    func requestAccess() async throws {
        guard monitoring else { throw AudioBackendError.unsupported("Start audio discovery before requesting access.") }
        requested += 1
        if suspendRequest { await withCheckedContinuation { requestWaiter = $0 } }
        if let requestError { throw requestError }
        accessWasRequested = true
        if access != .verified { access = .waitingForAudio }
        publish()
    }
    var accessPrompts = 0
    func promptForAccess() { accessPrompts += 1 }
    func accessWasLost() { access = .notRequested; accessWasRequested = false }
    func setAdjustment(_ adjustment: AppAdjustment, for clientID: String) {
        adjustmentCalls.append(clientID); desired[clientID] = adjustment
        publish()
    }
    func removeAdjustment(for clientID: String) { desired.removeValue(forKey: clientID); publish() }
    func setProcessingEnabled(_ enabled: Bool) throws {
        if enabled && !accessWasRequested { throw AudioBackendError.unsupported("Request system audio access before enabling app levels.") }
        self.enabled = enabled
        publish()
    }
    func selectOutput(_ deviceID: UInt32) throws {
        if let outputFailure { throw outputFailure }
        outputActions.append("select:\(deviceID)")
    }
    func setOutputVolume(_ volume: Double, for deviceID: UInt32) throws {
        if let outputFailure { throw outputFailure }
        outputActions.append("\(deviceID):volume:\(volume)")
    }
    func setOutputMuted(_ muted: Bool, for deviceID: UInt32) throws {
        if let outputFailure { throw outputFailure }
        outputActions.append("\(deviceID):muted:\(muted)")
    }
    func stop() { monitoring = false; enabled = false; accessWasRequested = false; access = .notRequested }
    func drain(timeout: TimeInterval) { drains.append(timeout) }

    private func publish() {
        onSnapshot?(AudioSnapshot(clients: lastClients, outputs: lastOutputs, defaultOutputID: lastDefaultOutputID,
                                  accessState: access, outputUnsupportedReason: lastUnsupportedReason))
    }
    func emit(_ clients: [AudioClientSnapshot]) {
        lastClients = clients
        publish()
    }
    func emitOutputs(_ outputs: [AudioOutputSnapshot], defaultID: UInt32?, unsupportedReason: String? = nil) {
        lastOutputs = outputs; lastDefaultOutputID = defaultID; lastUnsupportedReason = unsupportedReason
        publish()
    }
    func setAccess(_ access: AudioAccessState) {
        self.access = access
        if access == .denied { enabled = false; accessWasRequested = false }
        publish()
    }
    /// A discovery failure once the backend's own retries are exhausted.
    func emitFailure(_ message: String) { onFailure?(message) }
    /// A non-permission access reader failure, which turns processing off before reporting.
    func failAccessReader(_ message: String) {
        enabled = false; access = .notRequested
        publish()
        onFailure?(message)
    }
}

@MainActor
private final class TestLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    var failure: AudioBackendError?
    var statusAfterChange: SMAppService.Status?
    var calls: [String] = []
    func register() throws { try record("register") }
    func unregister() throws { try record("unregister") }
    private func record(_ call: String) throws {
        calls.append(call)
        if let statusAfterChange { status = statusAfterChange }
        if let failure { throw failure }
    }
}

@MainActor
private final class TestPermission: AudioAccessPermissionProviding {
    var current: AudioAccessPermission = .unavailable
    func fresh() async -> AudioAccessPermission? { current }
    var answer: AudioAccessPermission = .unavailable
    var requests = 0
    func request(completion: @escaping @MainActor (AudioAccessPermission) -> Void) {
        requests += 1
        if answer != .unavailable { current = answer }
        completion(answer)
    }
}

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 100)
}

/// Lets tasks started by the model run.
@MainActor private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

private func client(_ id: String, active: Bool) -> AudioClientSnapshot {
    AudioClientSnapshot(id: id, name: id, isRunningOutput: active)
}

@MainActor private func makeStore(defaults: InMemoryPreferences = InMemoryPreferences(),
                                  saved: [String: AppAdjustment] = [:], hasEnabled: Bool = false, paused: Bool = false) -> PreferenceStore {
    let store = PreferenceStore(defaults: defaults)
    for (id, value) in saved { store.save(value, for: id) }
    if hasEnabled { store.setActivation(hasEnabled: true, paused: paused) }
    return store
}

@MainActor private func makeModel(store: PreferenceStore? = nil, loginItem: TestLoginItem = TestLoginItem(),
                                  permission: TestPermission = TestPermission(), now: @escaping () -> Date = Date.init) -> (MixerModel, TestBackend) {
    let backend = TestBackend()
    return (MixerModel(backend: backend, store: store ?? makeStore(), loginItem: loginItem, permission: permission, now: now), backend)
}

/// The production order from first enable to applying levels: waiting, enabled, then verified.
@MainActor private func makeReadyModel(store: PreferenceStore? = nil, clients: [AudioClientSnapshot],
                                       now: @escaping () -> Date = Date.init) async -> (MixerModel, TestBackend) {
    let (model, backend) = makeModel(store: store, now: now)
    model.start(); backend.emit(clients)
    await model.enableAppLevels()
    #expect(model.state == .waitingForAudio)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
    return (model, backend)
}

// MARK: - Startup and activation

@MainActor @Test func silentStartupWaitsWithoutFailureOrRepeatedRequests() async throws {
    let store = makeStore(hasEnabled: true)
    let (model, backend) = makeModel(store: store)
    model.start()
    #expect(model.state == .waitingForAudio)
    for _ in 0..<20 where backend.requested == 0 { await Task.yield() }
    for _ in 0..<20 where model.isRequestingAccess { await Task.yield() }
    #expect(backend.requested == 1 && backend.enabled)
    #expect(!model.isRequestingAccess)
    #expect(!model.isApplyingLevels && model.state == .waitingForAudio)
    for _ in 0..<10 { backend.emit([]) }
    #expect(model.state == .waitingForAudio && model.applications.isEmpty)
    #expect(backend.requested == 1)
    #expect(store.hasEnabled && !store.paused)
}

@MainActor @Test func queuedStartupCannotOverrideAnImmediatePauseOrStop() async throws {
    for pause in [true, false] {
        let store = makeStore(hasEnabled: true)
        let (model, backend) = makeModel(store: store)
        model.start()
        if pause { model.pauseAppLevels() } else { model.stop() }
        await settle()
        #expect(backend.requested == 0 && !backend.enabled)
        if pause { #expect(model.state == .paused && store.paused) }
    }
}

@MainActor @Test func savedLevelsAreReplayedBeforeActivation() async throws {
    let saved = AppAdjustment(volume: 0.3, muted: true)
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": saved], hasEnabled: true))
    model.start()
    #expect(backend.desired["Music"] == saved)
    #expect(backend.requested == 0)
    for _ in 0..<20 where !backend.enabled { await Task.yield() }
    #expect(backend.requested == 1 && backend.enabled)
}

@MainActor @Test func pausedRelaunchReplaysLevelsWithoutRequestingAccess() async throws {
    let saved = AppAdjustment(volume: 0.3)
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": saved], hasEnabled: true, paused: true))
    model.start()
    await settle()
    #expect(model.state == .paused)
    #expect(backend.requested == 0 && !backend.enabled)
    #expect(backend.desired["Music"] == saved)
}

@MainActor @Test func ignoredAppIsReplayedAndStaysOutOfTheRows() {
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": AppAdjustment(volume: 0.3, ignored: true)]))
    model.start()
    #expect(backend.desired["Music"]?.ignored == true)
    backend.emit([client("Music", active: true)])
    #expect(model.applications.isEmpty)
}

@MainActor @Test func silentActiveIOKeepsEditableSavedLevelsAndBecomesReadyOnSignal() async throws {
    let (model, backend) = makeModel()
    model.start(); backend.emit([client("Music", active: true)])
    await model.enableAppLevels()
    model.setVolume(0.35, for: "Music")
    model.toggleMute(for: "Music")
    #expect(model.state == .waitingForAudio)
    #expect(model.applications.first?.isAdjustable == true)
    #expect(model.applications.first?.isApplied == false)
    #expect(model.applications.first?.unavailableReason == nil)
    #expect(backend.desired["Music"] == AppAdjustment(volume: 0.35, muted: true))
    for _ in 0..<10 { backend.emit([client("Music", active: true)]) }
    #expect(model.state == .waitingForAudio && backend.requested == 1)
    backend.setAccess(.verified)
    #expect(model.state == .ready && model.isApplyingLevels)
    #expect(backend.requested == 1)
}

@MainActor @Test func lateVerificationCannotResumePausedOrStoppedLevels() async throws {
    let (model, backend) = makeModel()
    model.start(); await model.enableAppLevels()
    model.pauseAppLevels()
    backend.setAccess(.verified)
    #expect(model.state == .paused && !backend.enabled)
    backend.suspendRequest = true
    let request = Task { await model.enableAppLevels() }
    for _ in 0..<20 where backend.requestWaiter == nil { await Task.yield() }
    let waiter = try #require(backend.requestWaiter)
    model.stop()
    waiter.resume(); await request.value
    #expect(!backend.enabled && !model.isRequestingAccess)
    #expect(!model.isApplyingLevels)
}

@MainActor @Test func resumingAfterPauseIsReadyAtOnceWhenAccessIsAlreadyVerified() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.pauseAppLevels()
    #expect(model.state == .paused && !backend.enabled)
    await model.enableAppLevels()
    #expect(model.state == .ready && backend.enabled)
    #expect(backend.requested == 2)
}

@MainActor @Test func aFirstRunAppCanBeAdjustedAndAccessIsRequestedOnceTheChangeIsFinished() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.emit([client("Music", active: true)])
    #expect(model.applications.first?.isAdjustable == true)
    #expect(model.applications.first?.unavailableReason == nil)

    model.setVolume(0.5, for: "Music")
    #expect(backend.desired["Music"]?.volume == 0.5)
    await settle()
    #expect(backend.requested == 0 && model.state == .needsAccess)

    model.finishedAdjusting()
    await settle()
    #expect(backend.requested == 1 && backend.enabled && model.state == .waitingForAudio)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
}

@MainActor @Test func mutingOnFirstRunRequestsAccessWithoutWaitingForASliderToEnd() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.emit([client("Music", active: true)])
    model.toggleMute(for: "Music")
    await settle()
    #expect(backend.requested == 1 && backend.enabled)
}

@MainActor @Test func aKeyboardChangeOnFirstRunRequestsAccessWhenThePanelCloses() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.emit([client("Music", active: true)])
    model.beginPanelSession()
    model.setVolume(0.5, for: "Music")
    await settle()
    #expect(backend.requested == 0)
    model.endPanelSession()
    await settle()
    #expect(backend.requested == 1)
}

@MainActor @Test func nothingRequestsAccessUntilALevelNeedsIt() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.emit([client("Music", active: true)])
    model.beginPanelSession()
    model.setVolume(1, for: "Music")
    model.finishedAdjusting()
    model.endPanelSession()
    await settle()
    #expect(backend.requested == 0 && model.state == .needsAccess)
}

@MainActor @Test func theWelcomeWindowIsOfferedOnceEverAndAsksForNoAccess() {
    let defaults = InMemoryPreferences()
    let (model, backend) = makeModel(store: makeStore(defaults: defaults))
    model.start()
    #expect(model.shouldShowWelcome)
    model.noteWelcomeShown()
    #expect(!model.shouldShowWelcome && backend.requested == 0 && model.state == .needsAccess)
    let (relaunched, _) = makeModel(store: makeStore(defaults: defaults))
    #expect(!relaunched.shouldShowWelcome)
}

@MainActor @Test func promptingForAccessAsksOnceAndLeavesAppLevelsOff() async throws {
    let (model, backend) = makeModel()
    model.start()
    model.promptForAccess()
    model.promptForAccess()
    await settle()
    #expect(backend.accessPrompts == 1 && model.hasPromptedForAccess)
    #expect(backend.requested == 0 && !backend.enabled && model.state == .needsAccess)
}

@MainActor @Test func theReportedPermissionIsReadAtStartAndFollowsChanges() async {
    let permission = TestPermission()
    permission.current = .denied
    let (model, _) = makeModel(permission: permission)
    model.start()
    #expect(model.accessPermission == .denied)
    permission.current = .allowed
    await model.refreshAccessPermission()
    #expect(model.accessPermission == .allowed)
}

@MainActor @Test func askingUsesTheSystemRequestAndOnlyFallsBackWhenItIsMissing() {
    let permission = TestPermission()
    permission.answer = .allowed
    let (model, backend) = makeModel(permission: permission)
    model.start()
    model.promptForAccess()
    #expect(permission.requests == 1 && backend.accessPrompts == 0)
    #expect(model.accessPermission == .allowed && model.state == .needsAccess && backend.requested == 0)

    let (fallback, fallbackBackend) = makeModel()
    fallback.start()
    fallback.promptForAccess()
    #expect(fallbackBackend.accessPrompts == 1)
}

@MainActor @Test func theCallerHearsWhenMacOSHasAnswered() {
    let permission = TestPermission()
    permission.current = .notAsked
    permission.answer = .denied
    let (model, _) = makeModel(permission: permission)
    model.start()
    var answers = 0
    model.promptForAccess { answers += 1 }
    #expect(answers == 1 && model.accessPermission == .denied)
}

@MainActor @Test func aStillUnansweredRequestCanBeMadeAgain() async {
    let permission = TestPermission()
    permission.current = .notAsked
    permission.answer = .denied
    let (model, _) = makeModel(permission: permission)
    model.start()
    model.promptForAccess()
    permission.current = .notAsked
    await model.refreshAccessPermission()
    model.promptForAccess()
    #expect(permission.requests == 2)
}

@MainActor @Test func setupHelpStaysHiddenOnceMacOSReportsAccessIsAllowed() async throws {
    let permission = TestPermission()
    let (model, backend) = makeModel(permission: permission)
    model.start()
    backend.emit([client("Music", active: true)])
    await model.enableAppLevels()
    #expect(model.showsAccessHelp)
    permission.current = .allowed
    await model.refreshAccessPermission()
    #expect(!model.showsAccessHelp && !model.showsFirstSoundHint)
}

@MainActor @Test func losingAccessStopsProcessingAndGettingItBackResumes() async throws {
    let permission = TestPermission()
    permission.current = .allowed
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": AppAdjustment(muted: true)]), permission: permission)
    model.start()
    await model.enableAppLevels()
    backend.setAccess(.verified)
    #expect(model.state == .ready && backend.enabled)

    permission.current = .denied
    await model.refreshAccessPermission()
    #expect(model.state == .accessDenied && !backend.enabled && model.statusIsNotApplying)
    backend.emit([client("Music", active: true)])
    #expect(model.state == .accessDenied)

    permission.current = .allowed
    await model.refreshAccessPermission()
    await settle()
    #expect(model.state == .waitingForAudio && backend.enabled)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
}

@MainActor @Test func aFirstLaunchWithoutAccessSaysSoAndAllowingClearsIt() async throws {
    let permission = TestPermission()
    permission.current = .notAsked
    permission.answer = .allowed
    let (model, _) = makeModel(permission: permission)
    model.start()
    #expect(model.state == .needsAccess && model.needsAudioAccess)
    #expect(model.statusIsNotApplying && model.statusDetail == "Audio access needed")

    model.promptForAccess()
    #expect(!model.needsAudioAccess && !model.statusIsNotApplying && model.statusDetail == "App levels off")
}

@MainActor @Test func aLaunchThatLostItsAnswerShowsAccessNeededWhileWaiting() async throws {
    let permission = TestPermission()
    permission.current = .notAsked
    let (model, _) = makeModel(store: makeStore(hasEnabled: true), permission: permission)
    model.start()
    await settle()
    #expect(model.state == .waitingForAudio && model.needsAudioAccess && model.statusIsNotApplying)
}

@MainActor @Test func withoutThePermissionCheckAFirstLaunchStaysQuiet() {
    let (model, _) = makeModel()
    model.start()
    #expect(!model.needsAudioAccess && !model.statusIsNotApplying && model.statusDetail == "App levels off")
}

@MainActor @Test func tryAgainGoesByMacOSAndCannotPretendAccessCameBack() async throws {
    let permission = TestPermission()
    permission.current = .allowed
    let (model, backend) = makeModel(permission: permission)
    model.start()
    await model.enableAppLevels()
    backend.setAccess(.verified)
    #expect(model.state == .ready)

    permission.current = .denied
    await model.refreshAccessPermission()
    await model.retryAccess()
    #expect(model.state == .accessDenied && !backend.enabled)

    // Never asked: the system prompt, and a decline leaves the notice in place.
    permission.current = .notAsked
    permission.answer = .denied
    await model.retryAccess()
    await settle()
    #expect(permission.requests == 1 && model.state == .accessDenied && !backend.enabled)

    // Coming back must prove itself with real audio, not the verification from before.
    permission.current = .allowed
    await model.retryAccess()
    await settle()
    #expect(model.state == .waitingForAudio && backend.enabled)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
}

@MainActor @Test func tryAgainBeforeLevelsWereEverOnStartsThemOnlyForASavedLevel() async throws {
    let permission = TestPermission()
    permission.current = .denied
    let (model, backend) = makeModel(permission: permission)
    model.start()
    backend.emit([client("Music", active: true)])
    #expect(model.state == .needsAccess && model.needsAudioAccess)

    // Access was turned on in System Settings with nothing adjusted, so nothing needs to start.
    permission.current = .allowed
    await model.retryAccess()
    await settle()
    #expect(model.state == .needsAccess && !model.needsAudioAccess && backend.requested == 0 && !backend.enabled)

    let saved = TestPermission()
    saved.current = .denied
    let (waiting, waitingBackend) = makeModel(store: makeStore(saved: ["Music": AppAdjustment(volume: 0.5)]), permission: saved)
    waiting.start()
    waitingBackend.emit([client("Music", active: true)])
    #expect(waiting.state == .needsAccess)
    saved.current = .allowed
    await waiting.retryAccess()
    await settle()
    #expect(waiting.state == .waitingForAudio && waitingBackend.requested == 1 && waitingBackend.enabled)
}

@MainActor @Test func aPermissionResetWhileLevelsRunCountsAsLosingAccess() async throws {
    let permission = TestPermission()
    permission.current = .allowed
    let (model, backend) = makeModel(permission: permission)
    model.start()
    await model.enableAppLevels()
    permission.current = .notAsked
    await model.refreshAccessPermission()
    #expect(model.state == .accessDenied && !backend.enabled)
}

@MainActor @Test func aPauseOrFirstRunIsLeftAloneWhenAccessChanges() async throws {
    let permission = TestPermission()
    permission.current = .allowed
    let (paused, _) = makeModel(store: makeStore(hasEnabled: true, paused: true), permission: permission)
    paused.start()
    permission.current = .denied
    await paused.refreshAccessPermission()
    #expect(paused.state == .paused)

    let firstRunPermission = TestPermission()
    firstRunPermission.current = .notAsked
    let (firstRun, _) = makeModel(permission: firstRunPermission)
    firstRun.start()
    firstRunPermission.current = .denied
    await firstRun.refreshAccessPermission()
    #expect(firstRun.state == .needsAccess)
}

@MainActor @Test func startingWithAccessDeniedSaysSoInsteadOfWaiting() async throws {
    let permission = TestPermission()
    permission.current = .denied
    let (model, backend) = makeModel(store: makeStore(hasEnabled: true), permission: permission)
    model.start()
    await settle()
    #expect(model.state == .accessDenied && !backend.enabled && backend.requested == 0)
}

@MainActor @Test func revokingAccessIsReportedEvenAfterAudioCameThroughThisSession() async throws {
    let permission = TestPermission()
    permission.current = .allowed
    let (model, backend) = makeModel(permission: permission)
    model.start()
    await model.enableAppLevels()
    backend.setAccess(.verified)
    #expect(model.isAccessConfirmed)
    permission.current = .notAsked
    await model.refreshAccessPermission()
    #expect(!model.isAccessConfirmed)
}

@MainActor @Test func withoutThePermissionCheckRealAudioIsTheOnlyProofOfAccess() async throws {
    let (model, backend) = makeModel()
    model.start()
    model.promptForAccess()
    #expect(!model.isAccessConfirmed)
    await model.enableAppLevels()
    #expect(!model.isAccessConfirmed)
    backend.setAccess(.verified)
    #expect(model.isAccessConfirmed)
}

// MARK: - Failure and recovery

@MainActor @Test func accessReaderFailureStopsLevelsAndLaterVerificationCannotResume() async throws {
    let (model, backend) = makeModel()
    model.start(); await model.enableAppLevels()
    backend.setAccess(.denied)
    #expect(model.state == .accessDenied && !backend.enabled)
    await model.enableAppLevels()
    #expect(model.state == .waitingForAudio && backend.enabled)
    backend.failAccessReader("Create audio callback failed (42).")
    #expect(model.state == .failed("Create audio callback failed (42)."))
    #expect(!backend.enabled)
    backend.setAccess(.verified)
    #expect(model.state == .failed("Create audio callback failed (42)."))
}

/// `CoreAudioBackend` reports denial by snapshot. These cover the generic thrown-error handling.
@MainActor @Test func aThrownRequestErrorStopsLevels() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.requestError = .permissionDenied
    await model.enableAppLevels()
    #expect(model.state == .accessDenied && !backend.enabled)
    backend.requestError = .operationFailed("Create audio callback", 42)
    await model.enableAppLevels()
    #expect(model.state == .failed("Create audio callback failed (42)."))
    #expect(!backend.enabled)
}

@MainActor @Test func failedThenRetryReachesReady() async throws {
    let (model, backend) = makeModel()
    model.start()
    backend.requestError = .operationFailed("Create audio callback", 42)
    await model.enableAppLevels()
    #expect(model.state == .failed("Create audio callback failed (42)."))
    backend.requestError = nil
    await model.enableAppLevels()
    backend.setAccess(.verified)
    #expect(model.state == .ready && backend.enabled)
}

@MainActor @Test func startupMonitoringFailureRecoversThroughTryAgain() async throws {
    let saved = AppAdjustment(volume: 0.3, muted: true)
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": saved], hasEnabled: true))
    backend.startError = .operationFailed("Read outputs", 42)
    model.start()
    #expect(model.state == .failed("Read outputs failed (42)."))
    #expect(backend.desired["Music"] == saved)
    await model.enableAppLevels()
    #expect(model.state == .failed("Read outputs failed (42)."))
    #expect(backend.monitoringStarts == 2 && backend.requested == 0)
    backend.startError = nil
    await model.enableAppLevels()
    #expect(model.state == .waitingForAudio && backend.enabled)
    #expect(backend.monitoringStarts == 3 && backend.requested == 1)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
}

@MainActor @Test func monitoringRecoveryOnFirstRunDoesNotRequestAccessBeforeItIsNeeded() async throws {
    let (model, backend) = makeModel()
    backend.startError = .operationFailed("Read outputs", 42)
    model.start()
    backend.startError = nil
    await model.enableAppLevels()
    #expect(model.state == .needsAccess)
    #expect(backend.monitoringStarts == 2 && backend.requested == 0 && !backend.enabled)
    #expect(!model.isRequestingAccess)
    backend.setAccess(.notRequested)
    #expect(model.state == .needsAccess)
    await model.enableAppLevels()
    #expect(backend.monitoringStarts == 2 && backend.requested == 1 && backend.enabled)
}

@MainActor @Test func monitoringRecoveryKeepsASavedPause() async throws {
    let (model, backend) = makeModel(store: makeStore(hasEnabled: true, paused: true))
    backend.startError = .operationFailed("Read outputs", 42)
    model.start()
    backend.startError = nil
    await model.enableAppLevels()
    #expect(model.state == .paused)
    #expect(backend.requested == 0 && !backend.enabled)
}

@MainActor @Test func monitoringRecoveryFromAThrownDenialRetriesAccess() async throws {
    let (model, backend) = makeModel(store: makeStore(hasEnabled: true))
    backend.startError = .permissionDenied
    model.start()
    #expect(model.state == .accessDenied)
    backend.startError = nil
    await model.enableAppLevels()
    #expect(model.state == .waitingForAudio && backend.enabled)
    #expect(backend.monitoringStarts == 2 && backend.requested == 1)
}

@MainActor @Test func retryAfterALaterDenialDoesNotRestartMonitoring() async throws {
    let (model, backend) = makeModel()
    model.start(); await model.enableAppLevels()
    backend.setAccess(.denied)
    #expect(model.state == .accessDenied)
    await model.enableAppLevels()
    #expect(backend.monitoringStarts == 1)
    #expect(model.state == .waitingForAudio && backend.enabled)
    backend.setAccess(.verified)
    #expect(model.state == .ready)
}

@MainActor @Test func enablingAfterStopDoesNotRestartMonitoring() async throws {
    let (model, backend) = makeModel()
    model.start(); model.stop()
    await model.enableAppLevels()
    #expect(backend.monitoringStarts == 1 && backend.requested == 0)
}

@MainActor @Test func discoveryFailureStopsActiveLevelsAndLaterVerificationCannotResume() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    backend.emitFailure("Read outputs failed (42).")
    #expect(model.state == .failed("Read outputs failed (42)."))
    #expect(!backend.enabled)
    backend.setAccess(.verified)
    #expect(model.state == .failed("Read outputs failed (42)."))
}

@MainActor @Test func discoveryFailureLeavesAnIdleStateUntouched() async throws {
    let (firstRun, firstRunBackend) = makeModel()
    firstRun.start()
    firstRunBackend.emitFailure("Read outputs failed (42).")
    #expect(firstRun.state == .needsAccess)

    let (paused, pausedBackend) = makeModel(store: makeStore(hasEnabled: true, paused: true))
    paused.start()
    pausedBackend.emitFailure("Read outputs failed (42).")
    #expect(paused.state == .paused)

    let (failed, failedBackend) = await makeReadyModel(clients: [])
    failedBackend.emitFailure("First.")
    failedBackend.emitFailure("Second.")
    #expect(failed.state == .failed("First."))
}

// MARK: - Rows

@MainActor @Test func draggingUnmutesAndPausePreventsIneffectiveEdits() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.toggleMute(for: "Music")
    #expect(model.applications.first?.muted == true)
    model.setVolume(0.42, for: "Music")
    #expect(model.applications.first?.muted == false)
    #expect(backend.desired["Music"]?.volume == 0.42)
    model.pauseAppLevels()
    model.setVolume(0.1, for: "Music")
    #expect(backend.desired["Music"]?.volume == 0.42)
    #expect(model.applications.first?.isAdjustable == false)
}

@MainActor @Test func rowsStayStableAndExpiredNotificationsLeaveOnReopen() throws {
    let clock = TestClock()
    let (model, backend) = makeModel(now: { clock.date })
    model.start(); backend.emit([client("Music", active: true)])
    model.beginPanelSession()
    clock.date.addTimeInterval(1)
    backend.emit([client("Music", active: true), client("Messages", active: true)])
    #expect(model.applications.map(\.id) == ["Music", "Messages"])
    backend.emit([client("Music", active: true), client("Messages", active: false)])
    clock.date.addTimeInterval(30)
    #expect(model.applications.map(\.id).contains("Messages"))
    model.endPanelSession(); model.beginPanelSession()
    #expect(model.applications.map(\.id) == ["Music"])
}

@MainActor @Test func runningAppsSortByMostRecentStartThenRecentActivity() {
    let clock = TestClock()
    let (model, backend) = makeModel(now: { clock.date })
    model.start()
    backend.emit([client("A", active: true), client("C", active: true), client("D", active: true)])
    clock.date.addTimeInterval(1)
    backend.emit([client("A", active: true), client("B", active: true), client("C", active: true), client("D", active: true)])
    clock.date.addTimeInterval(1)
    backend.emit([client("A", active: true), client("B", active: true), client("C", active: false), client("D", active: true)])
    clock.date.addTimeInterval(1)
    backend.emit([client("A", active: true), client("B", active: true), client("C", active: false), client("D", active: false)])
    #expect(model.applications.map(\.id) == ["B", "A", "D", "C"])
}

@MainActor @Test func fractionalAdjustmentRetainsSilentAppAndIgnoreCanBeUndone() async throws {
    let clock = TestClock()
    let (model, backend) = await makeReadyModel(clients: [client("Messages", active: true)], now: { clock.date })
    model.setVolume(0.97, for: "Messages")
    backend.emit([client("Messages", active: false)])
    clock.date.addTimeInterval(31)
    #expect(model.applications.map(\.id) == ["Messages"])
    model.ignoreApplication("Messages")
    #expect(model.applications.isEmpty)
    #expect(model.savedApplications.first?.adjustment == AppAdjustment(ignored: true))
    model.removeSavedApplication("Messages")
    #expect(model.savedApplications.isEmpty)
    #expect(backend.desired["Messages"] == nil)
}

@MainActor @Test func dragEndingNearTheTopSnapsToFullAndRemovesTheEntry() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    #expect(model.savedAdjustments["Music"]?.volume == 0.5)
    model.setVolume(0.99, for: "Music")
    #expect(backend.desired["Music"]?.volume == 1)
    #expect(backend.desired["Music"]?.needsProcessing == false)
    #expect(model.savedAdjustments["Music"] == nil)
    model.setVolume(0.97, for: "Music")
    #expect(model.savedAdjustments["Music"]?.volume == 0.97)
    model.setVolume(2, for: "Music")
    #expect(model.savedAdjustments["Music"] == nil)
    model.setVolume(-1, for: "Music")
    #expect(model.savedAdjustments["Music"]?.volume == 0)
    model.setVolume(.nan, for: "Music")
    #expect(model.savedAdjustments["Music"]?.volume == 0)
}

@MainActor @Test func resetRemovesSavedEntryAndSendsUnityToBackend() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("org.example.notInstalled", active: true)])
    model.setVolume(0.5, for: "org.example.notInstalled")
    #expect(model.savedApplications.count == 1)
    model.resetVolume(for: "org.example.notInstalled")
    #expect(backend.desired["org.example.notInstalled"] == AppAdjustment())
    #expect(model.savedApplications.isEmpty)
}

@MainActor @Test func appQuitDuringPanelKeepsDisabledRowUntilReopen() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true), client("Chat", active: true)])
    model.setVolume(0.5, for: "Music")
    model.beginPanelSession()
    backend.emit([])
    let saved = try #require(model.applications.first { $0.id == "Music" })
    #expect(!saved.isAdjustable && saved.volume == 0.5)
    #expect(saved.unavailableReason == "Not running. Your saved level is kept.")
    let unsaved = try #require(model.applications.first { $0.id == "Chat" })
    #expect(!unsaved.isAdjustable && unsaved.volume == 1)
    #expect(unsaved.unavailableReason == "No longer active.")
    model.endPanelSession(); model.beginPanelSession()
    #expect(model.applications.isEmpty)
}

@MainActor @Test func idleSavedMuteCanBeEditedWithoutPretendingItIsApplied() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.toggleMute(for: "Music")
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: false,
        unavailableReason: "Waiting for output IO.", isAdjustmentApplied: false)])
    let row = try #require(model.applications.first)
    #expect(row.isAdjustable && !row.isApplied)
    #expect(row.unavailableReason == nil)
    #expect(row.volume == 1 && row.muted)
    model.toggleMute(for: "Music")
    #expect(backend.desired["Music"]?.muted == false)
}

@MainActor @Test func startingPipelineKeepsControlsWithoutACaptionAndPauseKeepsSavedValues() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true,
        unavailableReason: "Waiting for audio callback.", isAdjustmentApplied: false, isAdjustmentPending: true)])
    #expect(model.applications.first?.isAdjustable == true)
    #expect(model.applications.first?.isApplied == false)
    #expect(model.applications.first?.unavailableReason == nil)
    model.toggleMute(for: "Music")
    #expect(backend.desired["Music"]?.muted == true)
    model.setVolume(0.25, for: "Music")
    #expect(backend.desired["Music"]?.volume == 0.25)
    #expect(backend.desired["Music"]?.muted == false)
    #expect(model.applications.first?.unavailableReason == nil)
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true)])
    #expect(model.applications.first?.isApplied == true)
    #expect(model.applications.first?.unavailableReason == nil)
    #expect(model.applications.first?.volume == 0.25)
    model.pauseAppLevels()
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true,
        unavailableReason: "App levels are paused.", isAdjustmentApplied: false)])
    #expect(model.applications.first?.unavailableReason == nil)
    #expect(model.applications.first?.isAdjustable == false)
    #expect(model.applications.first?.volume == 0.25)
}

@MainActor @Test func failedPipelineMovesItsCauseToDetailAndPreventsIneffectiveEdits() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    let failure = "Start application audio failed (-10851)."
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false,
        unavailableReason: failure, isAdjustmentApplied: false, canRetry: true)])
    let row = try #require(model.applications.first)
    #expect(!row.isAdjustable && !row.isApplied)
    #expect(row.canRetry)
    #expect(row.unavailableReason == "Couldn’t apply your saved level. This app stays at its own volume.")
    #expect(row.unavailableDetail == failure)
    #expect(row.volume == 0.5)
    model.setVolume(0.25, for: "Music"); model.toggleMute(for: "Music")
    #expect(backend.desired["Music"] == AppAdjustment(volume: 0.5))
}

@MainActor @Test func aClientRejectionKeepsItsOwnCaption() async throws {
    let caption = "Plays to another output. Can’t adjust it here."
    let (model, _) = await makeReadyModel(clients: [AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true,
        isControllable: false, unavailableReason: caption, isAdjustmentApplied: false)])
    let row = try #require(model.applications.first)
    #expect(row.unavailableReason == caption)
    #expect(row.unavailableDetail == nil && !row.canRetry && !row.isAdjustable)
}

@MainActor @Test func aRetryResendsTheSavedLevelOnlyForARetryableFailure() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    backend.adjustmentCalls = []

    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false,
        unavailableReason: "Duplex.", isAdjustmentApplied: false)])
    #expect(model.applications.first?.canRetry == false)
    model.retryApplication("Music")
    #expect(backend.adjustmentCalls.isEmpty)

    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false,
        unavailableReason: "Broken.", isAdjustmentApplied: false, canRetry: true)])
    model.retryApplication("Music")
    #expect(backend.adjustmentCalls == ["Music"])
    #expect(backend.desired["Music"] == AppAdjustment(volume: 0.5))
}

@MainActor @Test func anUnattributedProcessCannotBeSavedAsIgnored() async throws {
    let store = makeStore()
    let unattributed = AudioClientSnapshot(id: "unattributed:48213", name: "afplay", isRunningOutput: true, isControllable: false,
        unavailableReason: "Can’t adjust this app. Its sound is unchanged.", hasStableIdentity: false)
    let (model, backend) = makeModel(store: store)
    model.start(); backend.emit([unattributed, client("Music", active: true)])
    #expect(model.applications.first { $0.id == unattributed.id }?.canIgnore == false)
    #expect(model.applications.first { $0.id == "Music" }?.canIgnore == true)
    model.ignoreApplication(unattributed.id)
    #expect(store.apps.isEmpty && backend.desired.isEmpty)

    // A process that just left the snapshot is still known to be unstable.
    model.beginPanelSession()
    backend.emit([client("Music", active: true)])
    model.ignoreApplication(unattributed.id)
    #expect(store.apps.isEmpty)

    model.ignoreApplication("org.example.notRunning")
    #expect(store.apps["org.example.notRunning"]?.ignored == true)
}

// MARK: - Aggregates

@MainActor @Test func hasUnappliedApplicationsCountsOnlyRunningAppsWhoseLevelIsNotReachingThem() async throws {
    let saved = ["Music": AppAdjustment(volume: 0.5), "Slack": AppAdjustment(muted: true), "Ignored": AppAdjustment(volume: 0.5, ignored: true)]
    let (model, backend) = await makeReadyModel(store: makeStore(saved: saved), clients: [])
    func rejected(_ id: String, canRetry: Bool = false) -> AudioClientSnapshot {
        AudioClientSnapshot(id: id, name: id, isRunningOutput: true, isControllable: false,
                            unavailableReason: "Rejected.", isAdjustmentApplied: !saved.keys.contains(id), canRetry: canRetry)
    }

    backend.emit([rejected("Slack")])
    #expect(model.hasUnappliedApplications)

    backend.emit([rejected("Music", canRetry: true), client("Slack", active: true)])
    #expect(model.hasUnappliedApplications)
    backend.emit([client("Slack", active: true)])
    #expect(!model.hasUnappliedApplications)

    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isAdjustmentApplied: false, isAdjustmentPending: true)])
    #expect(!model.hasUnappliedApplications)

    backend.emit([rejected("Ignored"), rejected("Unadjusted")])
    #expect(!model.hasUnappliedApplications)

    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: false, isAdjustmentApplied: false)])
    #expect(!model.hasUnappliedApplications)

    backend.emit([rejected("Music")])
    #expect(model.hasUnappliedApplications)
    model.pauseAppLevels()
    #expect(!model.hasUnappliedApplications)
}

@MainActor @Test func hasRunningSourceFollowsOutputIOOfAppsThatAreNotIgnored() {
    let (model, backend) = makeModel(store: makeStore(saved: ["Ignored": AppAdjustment(ignored: true)]))
    model.start()
    #expect(!model.hasRunningSource)
    backend.emit([client("Music", active: false), client("Ignored", active: true)])
    #expect(!model.hasRunningSource)
    backend.emit([client("Music", active: true), client("Ignored", active: true)])
    #expect(model.hasRunningSource)
}

@MainActor @Test func statusSeparatesAChosenPauseFromLevelsThatFailedToApply() async throws {
    let (model, backend) = makeModel(store: makeStore(saved: ["Music": AppAdjustment(volume: 0.5)]))
    model.start()
    #expect(model.statusDetail == "App levels off" && !model.statusIsNotApplying && model.statusAnnouncement == nil)

    await model.enableAppLevels()
    #expect(model.statusDetail == "App levels on, waiting for sound" && !model.statusIsNotApplying && model.statusAnnouncement == nil)

    backend.setAccess(.verified)
    #expect(model.statusDetail == "App levels on" && !model.statusIsNotApplying && model.statusAnnouncement == nil)

    let failed = AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false,
                                     unavailableReason: "Broken.", isAdjustmentApplied: false, canRetry: true)
    backend.emit([failed])
    #expect(model.statusDetail == "Some app levels aren’t applied" && model.statusIsNotApplying)
    #expect(model.statusAnnouncement == model.statusDetail)
    backend.emit([client("Music", active: true)])
    #expect(model.statusDetail == "App levels on" && model.statusAnnouncement == nil)

    model.pauseAppLevels()
    #expect(model.statusDetail == "App levels paused" && model.statusIsNotApplying && model.statusAnnouncement == nil)

    await model.enableAppLevels()
    backend.setAccess(.denied)
    #expect(model.statusDetail == "Audio access off" && model.statusIsNotApplying && model.statusAnnouncement != nil)

    await model.enableAppLevels()
    backend.emitFailure("Broken.")
    #expect(model.statusDetail == "App levels stopped" && model.statusIsNotApplying && model.statusAnnouncement != nil)
}

@MainActor @Test func statusReportsAnUnsupportedOutputWhileLevelsAreOn() async throws {
    let (model, backend) = makeModel()
    model.start()
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "Headset")]
    backend.emitOutputs(outputs, defaultID: 7, unsupportedReason: "Duplex.")
    #expect(model.statusDetail == "App levels off" && !model.statusIsNotApplying)
    await model.enableAppLevels()
    #expect(model.statusDetail == "App levels unavailable on this output" && model.statusIsNotApplying)
    backend.setAccess(.verified)
    #expect(model.statusDetail == "App levels unavailable on this output" && model.statusAnnouncement == model.statusDetail)
    backend.emitOutputs(outputs, defaultID: 7)
    #expect(model.statusDetail == "App levels on" && !model.statusIsNotApplying)
}

@MainActor @Test func statusDoesNotBlameAnOutputWhenNoneIsCurrent() async throws {
    let (model, backend) = makeModel()
    model.start()
    await model.enableAppLevels()
    backend.emitOutputs([], defaultID: nil, unsupportedReason: "No system output is available.")
    #expect(model.statusDetail == "App levels unavailable without an output" && model.statusIsNotApplying)
}

@MainActor @Test func failureAnnouncementMentionsMutedAppsOnlyWhenOneIsSavedMuted() async throws {
    let (model, backend) = makeModel()
    model.start()
    await model.enableAppLevels()
    backend.emitFailure("Broken.")
    #expect(model.statusAnnouncement == "App levels stopped. Apps play without your adjustments.")

    let id = "com.example.muted"
    backend.emit([client(id, active: true)])
    await model.enableAppLevels()
    backend.setAccess(.verified)
    model.toggleMute(for: id)
    backend.emitFailure("Broken.")
    #expect(model.statusAnnouncement == "App levels stopped. Apps play without your adjustments, so muted apps can be heard.")
}

@MainActor @Test func changingALevelNeverAddsANoticeToThePanelWhenAccessHasWorked() async throws {
    let defaults = InMemoryPreferences()
    let (model, backend) = makeModel(store: makeStore(defaults: defaults))
    model.start(); backend.emit([client("Music", active: true)])
    await model.enableAppLevels()
    #expect(model.showsAccessHelp)
    backend.setAccess(.verified)
    #expect(!model.showsAccessHelp)
    model.setVolume(0.5, for: "Music")
    #expect(model.state == .ready && !model.showsAccessHelp)
    model.stop()

    // An ordinary relaunch waits for signal again, and a running app is no reason to explain access.
    let (relaunched, relaunchedBackend) = makeModel(store: makeStore(defaults: defaults))
    relaunched.start(); relaunchedBackend.emit([client("Music", active: true)])
    await relaunched.enableAppLevels()
    #expect(relaunched.state == .waitingForAudio && !relaunched.showsAccessHelp)
}

@MainActor @Test func aRowKeptAfterItsAppLeftIsNotLive() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.beginPanelSession()
    #expect(model.applications.first?.isLive == true)
    backend.emit([])
    #expect(model.applications.first?.isLive == false)
}

@MainActor @Test func snapshotBookkeepingDoesNotInvalidateViews() async throws {
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking {
        _ = model.previousClients; _ = model.lastActivity; _ = model.lastStart
    } onChange: { flag.fired = true }
    backend.emit([client("Music", active: true), client("Chat", active: true)])
    #expect(!flag.fired)
}

@Test func levelTextOnlyReportsNotAppliedForAnAppWithALevelToApply() {
    let half = LevelText.percent(0.5), full = LevelText.percent(1)
    #expect(LevelText.app(volume: 1, muted: false, applied: false) == full)
    #expect(LevelText.app(volume: 1, muted: false, applied: true) == full)
    #expect(LevelText.app(volume: 0.5, muted: false, applied: true) == half)
    #expect(LevelText.app(volume: 0.5, muted: false, applied: false) == "Not applied, saved at \(half)")
    #expect(LevelText.app(volume: 1, muted: true, applied: false) == "Not applied, saved as muted at \(full)")
    #expect(LevelText.app(volume: 0.5, muted: true, applied: true) == "Muted, \(half) when unmuted")
    #expect(LevelText.output(volume: 0.5, muted: true) == "Muted, \(half) when unmuted")
    #expect(LevelText.output(volume: 0.5, muted: false) == half)
}

@MainActor @Test func firstSoundHintShowsUntilAccessIsVerifiedEvenAfterRelaunch() async throws {
    let defaults = InMemoryPreferences()
    let (model, backend) = makeModel(store: makeStore(defaults: defaults))
    model.start()
    #expect(!model.showsFirstSoundHint)
    await model.enableAppLevels()
    #expect(model.showsFirstSoundHint)
    backend.emit([client("Music", active: true)])
    #expect(!model.showsFirstSoundHint)
    backend.emit([client("Music", active: false)])
    #expect(model.showsFirstSoundHint)
    backend.setAccess(.verified)
    #expect(!model.showsFirstSoundHint)
    model.stop()

    let (relaunched, _) = makeModel(store: makeStore(defaults: defaults))
    relaunched.start()
    await relaunched.enableAppLevels()
    #expect(relaunched.state == .waitingForAudio)
    #expect(!relaunched.showsFirstSoundHint)
}

@MainActor @Test func unsupportedOutputPublishesOneReasonAndNoRowCaptions() async throws {
    let reason = "This output also exposes microphone inputs."
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "Headset")]
    backend.emitOutputs(outputs, defaultID: 7, unsupportedReason: reason)
    backend.emit([AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false,
                                      unavailableReason: reason, isAdjustmentApplied: false),
                  AudioClientSnapshot(id: "Chat", name: "Chat", isRunningOutput: true, isControllable: false, unavailableReason: reason)])
    #expect(model.outputUnsupportedReason == reason)
    #expect(model.applications.count == 2)
    #expect(model.applications.allSatisfy { $0.unavailableReason == nil && !$0.isAdjustable && !$0.canRetry })
    #expect(model.applications.first { $0.id == "Music" }?.volume == 0.5)
    model.setVolume(0.25, for: "Music")
    #expect(backend.desired["Music"]?.volume == 0.5)

    backend.emitOutputs(outputs, defaultID: 7)
    #expect(model.outputUnsupportedReason == nil)
}

@MainActor @Test func noCurrentOutputKeepsTheReasonTheNoticeReadsAndNoRowCaptions() async throws {
    let reason = "No system output is available."
    let rejected = AudioClientSnapshot(id: "Music", name: "Music", isRunningOutput: true, isControllable: false, unavailableReason: reason)
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "Headset")]
    let (model, backend) = await makeReadyModel(clients: [client("Music", active: true)])
    model.setVolume(0.5, for: "Music")
    for access in [AudioAccessState.verified, .waitingForAudio] {
        backend.setAccess(access)
        backend.emitOutputs(outputs, defaultID: nil, unsupportedReason: reason)
        backend.emit([rejected])
        #expect(model.state == (access == .verified ? .ready : .waitingForAudio))
        #expect(model.currentOutput == nil)
        #expect(model.outputUnsupportedReason == reason)
        #expect(model.applications.map(\.id) == ["Music"])
        #expect(model.applications.allSatisfy { $0.unavailableReason == nil && !$0.isAdjustable })
    }
}

// MARK: - Session state

@MainActor @Test func clientsThatLeaveAreForgottenUnlessARowOrSavedLevelNeedsThem() async throws {
    let clock = TestClock()
    let (model, backend) = await makeReadyModel(clients: [client("Saved", active: true), client("Frozen", active: true), client("Gone", active: true)],
                                                now: { clock.date })
    model.setVolume(0.5, for: "Saved")
    backend.emit([client("Saved", active: true), client("Frozen", active: true), client("Gone", active: true)])
    model.beginPanelSession()
    backend.emit([client("Frozen", active: true)])
    model.endPanelSession()
    model.beginPanelSession()
    backend.emit([])

    #expect(Set(model.previousClients.keys) == ["Saved", "Frozen"])
    #expect(Set(model.lastStart.keys) == ["Saved", "Frozen"])
    #expect(Set(model.lastActivity.keys) == ["Saved", "Frozen", "Gone"])

    clock.date.addTimeInterval(31)
    model.endPanelSession()
    backend.emit([])
    #expect(Set(model.previousClients.keys) == ["Saved"])
    #expect(Set(model.lastStart.keys) == ["Saved"])
    #expect(Set(model.lastActivity.keys) == ["Saved"])
    #expect(model.savedApplications.first?.name == "Saved")
}

@MainActor @Test func quitDrainIsBounded() throws {
    let (model, backend) = makeModel()
    model.drainAudioTeardown()
    #expect(backend.drains.count == 1 && backend.drains[0] > 0 && backend.drains[0] <= 1)
}

// MARK: - Output

@MainActor @Test func outputDragSetsTheNewLevelBeforeUnmutingWithoutCaptureAccess() throws {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "test", name: "Test output", volume: 0.8, muted: true)], defaultID: 7)
    model.setOutputVolume(0.2)
    #expect(backend.outputActions == ["7:volume:0.2", "7:muted:false"])
    #expect(backend.requested == 0)
    #expect(model.state == .needsAccess)
}

@MainActor @Test func outputWritesNameTheDeviceTheirValuesCameFrom() throws {
    let (model, backend) = makeModel()
    model.start()
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: true),
                   AudioOutputSnapshot(id: 8, uid: "b", name: "B", volume: 0.2, muted: false)]
    backend.emitOutputs(outputs, defaultID: 7)
    model.toggleOutputMute()
    #expect(backend.outputActions == ["7:muted:false"])
    backend.outputActions = []
    backend.emitOutputs(outputs, defaultID: 8)
    model.toggleOutputMute()
    model.setOutputVolume(0.5)
    #expect(backend.outputActions == ["8:muted:true", "8:volume:0.5", "8:muted:false"])
    backend.outputActions = []
    backend.emitOutputs(outputs, defaultID: nil)
    model.toggleOutputMute()
    model.setOutputVolume(0.5)
    #expect(backend.outputActions.isEmpty)
}

@MainActor @Test func aDefaultOutputChangeMidDragWritesNothingToTheNewDevice() {
    let (model, backend) = makeModel()
    model.start()
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "AirPods", volume: 0.8, muted: false),
                   AudioOutputSnapshot(id: 8, uid: "b", name: "Speakers", volume: 0.2, muted: true)]
    backend.emitOutputs(outputs, defaultID: 7)
    model.setOutputVolumeDragging(true)
    model.setOutputVolume(0.85)
    #expect(backend.outputActions == ["7:volume:0.85"])

    backend.outputActions = []
    backend.emitOutputs(outputs, defaultID: 8)
    model.setOutputVolume(0.9)
    model.setOutputVolume(0.95)
    #expect(backend.outputActions.isEmpty)
    model.setOutputVolumeDragging(false)

    // Keyboard and accessibility changes send no editing events and use the current device.
    model.setOutputVolume(0.3)
    #expect(backend.outputActions == ["8:volume:0.3", "8:muted:false"])
}

@MainActor @Test func outputSliderFollowsThePointerWithoutWaitingForASnapshot() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: true)], defaultID: 7)
    model.setOutputVolume(0.3)
    #expect(model.outputVolume == 0.3 && !model.outputMuted)
}

@MainActor @Test func aSnapshotReadBeforeTheLatestWriteCannotMoveADraggedSlider() {
    let (model, backend) = makeModel()
    model.start()
    let stale = [AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)]
    backend.emitOutputs(stale, defaultID: 7)
    model.setOutputVolumeDragging(true)
    model.setOutputVolume(0.3)
    backend.emitOutputs(stale, defaultID: 7)
    #expect(model.outputVolume == 0.3)

    // Hardware has the final word once the drag ends, including a value it rounded.
    model.setOutputVolumeDragging(false)
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.31, muted: false)], defaultID: 7)
    #expect(model.outputVolume == 0.31)

    // A final reading that arrived during the drag shows once it ends, with no new snapshot.
    model.setOutputVolumeDragging(true)
    model.setOutputVolume(0.5)
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.49, muted: false)], defaultID: 7)
    #expect(model.outputVolume == 0.5)
    model.setOutputVolumeDragging(false)
    #expect(model.outputVolume == 0.49)
}

@MainActor @Test func aDragThatLandsExactlyKeepsItsLevelWhenItEnds() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: true)], defaultID: 7)
    // The backend reports nothing when the device reads back exactly what was written.
    model.setOutputVolumeDragging(true)
    model.setOutputVolume(0.3)
    model.setOutputVolumeDragging(false)
    #expect(model.outputVolume == 0.3 && !model.outputMuted)

    // The same goes for a mute that landed before a drag which then writes nothing.
    model.toggleOutputMute()
    model.setOutputVolumeDragging(true)
    model.setOutputVolumeDragging(false)
    #expect(model.outputVolume == 0.3 && model.outputMuted)
}

@MainActor @Test func theOutputMuteButtonShowsItsNewStateWithoutWaitingForASnapshot() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)], defaultID: 7)
    model.toggleOutputMute()
    #expect(model.outputMuted && model.outputVolume == 0.8)
    model.toggleOutputMute()
    #expect(!model.outputMuted)
    #expect(backend.outputActions == ["7:muted:true", "7:muted:false"])

    backend.outputFailure = .unsupported("Refused.")
    model.toggleOutputMute()
    #expect(!model.outputMuted)
}

@MainActor @Test func aFailedOutputWriteLeavesTheSliderOnTheRealLevel() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)], defaultID: 7)
    backend.outputFailure = .unsupported("Refused.")
    model.setOutputVolumeDragging(true)
    model.setOutputVolume(0.3)
    #expect(model.outputVolume == 0.8)
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.7, muted: false)], defaultID: 7)
    #expect(model.outputVolume == 0.7)
}

@MainActor @Test func anUnchangedSnapshotDoesNotRedrawThePanel() {
    let (model, backend) = makeModel()
    model.start()
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)]
    backend.emit([client("com.example.a", active: true)])
    backend.emitOutputs(outputs, defaultID: 7)
    final class Flag: @unchecked Sendable { var isSet = false }
    let redrawn = Flag()
    withObservationTracking {
        _ = model.outputVolume; _ = model.applications; _ = model.outputUnsupportedReason
    } onChange: {
        redrawn.isSet = true
    }
    backend.emitOutputs(outputs, defaultID: 7)
    #expect(!redrawn.isSet)
}

@MainActor @Test func closingThePanelReleasesADragThatNeverEnded() {
    let (model, backend) = makeModel()
    model.start()
    let outputs = [AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false),
                   AudioOutputSnapshot(id: 8, uid: "b", name: "B", volume: 0.2, muted: false)]
    backend.emitOutputs(outputs, defaultID: 7)
    model.beginPanelSession()
    model.setOutputVolumeDragging(true)
    backend.emitOutputs(outputs, defaultID: 8)
    model.endPanelSession()
    model.setOutputVolume(0.3)
    #expect(backend.outputActions == ["8:volume:0.3"])
}

@MainActor @Test func outputMuteToggleIsNoOpWithoutMuteControl() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8)], defaultID: 7)
    #expect(!model.canMuteOutput)
    model.toggleOutputMute()
    #expect(backend.outputActions.isEmpty)
}

@MainActor @Test func outputWithoutVolumeControlExplainsWhy() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "Monitor", identity: .display),
                         AudioOutputSnapshot(id: 8, uid: "b", name: "Interface", identity: .usbAudio),
                         AudioOutputSnapshot(id: 9, uid: "c", name: "Speakers", volume: 0.5, identity: .display)], defaultID: 7)
    #expect(model.outputVolumeUnavailableText == "macOS can’t change the volume over HDMI or DisplayPort. Use the connected device’s controls.")
    backend.emitOutputs(backend.lastOutputs, defaultID: 8)
    #expect(model.outputVolumeUnavailableText == "Volume control isn’t available for this output.")
    backend.emitOutputs(backend.lastOutputs, defaultID: 9)
    #expect(model.outputVolumeUnavailableText == nil)
    backend.emitOutputs(backend.lastOutputs, defaultID: nil)
    #expect(model.outputVolumeUnavailableText == nil)
}

@MainActor @Test func outputVolumeIsClampedBeforeReachingBackend() {
    let (model, backend) = makeModel()
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)], defaultID: 7)
    model.setOutputVolume(2)
    model.setOutputVolume(-1)
    model.setOutputVolume(.nan)
    #expect(backend.outputActions == ["7:volume:1.0", "7:volume:0.0"])
}

@MainActor @Test func outputFailuresStayWithTheOutputAndClearOnTheNextActionOrClose() async throws {
    let (model, backend) = await makeReadyModel(clients: [])
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)], defaultID: 7)

    let actions: [(String, () -> Void)] = [
        ("Couldn’t change this output’s volume.", { model.setOutputVolume(0.5) }),
        ("Couldn’t change this output’s mute setting.", { model.toggleOutputMute() }),
        ("Couldn’t switch to that output.", { model.selectOutput(7) }),
    ]
    for (message, action) in actions {
        backend.outputFailure = .unsupported("Set audio property failed ('nrdy').")
        action()
        #expect(model.outputError == message)
        #expect(model.outputErrorDetail == "Set audio property failed ('nrdy').")
        #expect(model.loginError == nil)
        #expect(model.state == .ready)
        backend.outputFailure = nil
        action()
        #expect(model.outputError == nil)
        #expect(model.outputErrorDetail == nil)
    }

    model.beginPanelSession()
    backend.outputFailure = .unsupported("This output is no longer available.")
    model.setOutputVolume(0.5)
    #expect(model.outputError != nil)
    model.endPanelSession()
    #expect(model.outputError == nil)
    #expect(model.outputErrorDetail == nil)
}

// MARK: - Login item

@MainActor @Test func loginItemAwaitingApprovalShowsTheToggleOnAndAsksForApproval() {
    let loginItem = TestLoginItem()
    loginItem.status = .requiresApproval
    let (model, _) = makeModel(loginItem: loginItem)
    model.start()
    #expect(model.loginItemNeedsApproval && model.openAtLogin)
    loginItem.status = .enabled
    model.refreshLoginItemStatus()
    #expect(!model.loginItemNeedsApproval && model.openAtLogin)
    loginItem.status = .notRegistered
    model.refreshLoginItemStatus()
    #expect(!model.loginItemNeedsApproval && !model.openAtLogin)
}

@MainActor @Test func loginItemFailureStaysWithSettingsAndStateComesFromTheService() async throws {
    let loginItem = TestLoginItem()
    let (model, backend) = makeModel(loginItem: loginItem)
    model.start()
    backend.emitOutputs([AudioOutputSnapshot(id: 7, uid: "a", name: "A", volume: 0.8, muted: false)], defaultID: 7)
    loginItem.failure = .unsupported("Login item refused.")
    model.setOpenAtLogin(true)
    #expect(loginItem.calls == ["register"])
    #expect(model.loginError == "Login item refused.")
    #expect(!model.openAtLogin)
    #expect(model.outputError == nil)

    backend.outputFailure = .unsupported("Output refused.")
    model.setOutputVolume(0.5)
    #expect(model.outputErrorDetail == "Output refused.")
    #expect(model.loginError == "Login item refused.")

    loginItem.failure = nil
    loginItem.statusAfterChange = .enabled
    model.setOpenAtLogin(true)
    #expect(model.loginError == nil && model.openAtLogin)
    #expect(model.outputErrorDetail == "Output refused.")

    loginItem.statusAfterChange = .notRegistered
    model.setOpenAtLogin(false)
    #expect(loginItem.calls == ["register", "register", "unregister"])
    #expect(!model.openAtLogin)

    loginItem.failure = .unsupported("Login item refused.")
    model.setOpenAtLogin(true)
    model.clearLoginError()
    #expect(model.loginError == nil)
}

// MARK: - Permission answers

@MainActor
private final class HeldPermission: AudioAccessPermissionProviding {
    var current: AudioAccessPermission = .notAsked
    var checks: [CheckedContinuation<AudioAccessPermission?, Never>] = []
    var pendingRequest: (@MainActor (AudioAccessPermission) -> Void)?
    var requests = 0
    func fresh() async -> AudioAccessPermission? { await withCheckedContinuation { checks.append($0) } }
    func request(completion: @escaping @MainActor (AudioAccessPermission) -> Void) {
        requests += 1
        pendingRequest = completion
    }
}

@MainActor private func makeModel(held: HeldPermission) -> MixerModel {
    MixerModel(backend: TestBackend(), store: makeStore(), loginItem: TestLoginItem(), permission: held)
}

@MainActor @Test func aCheckThatBeganBeforeAnAnswerCanNotUndoIt() async {
    let held = HeldPermission()
    let model = makeModel(held: held)
    model.start()
    let check = Task { await model.refreshAccessPermission() }
    await settle()
    model.promptForAccess()
    held.pendingRequest?(.allowed)
    #expect(model.accessPermission == .allowed)
    held.checks[0].resume(returning: .notAsked)
    await check.value
    #expect(model.accessPermission == .allowed)
}

@MainActor @Test func askingTwiceWhileMacOSIsAskingMakesOneRequest() {
    let held = HeldPermission()
    let model = makeModel(held: held)
    model.start()
    model.promptForAccess()
    model.promptForAccess()
    #expect(held.requests == 1)
    held.pendingRequest?(.denied)
    model.promptForAccess()
    #expect(held.requests == 2)
}

@MainActor @Test func aCheckWithNoAnswerKeepsTheLastKnownPermission() async {
    let held = HeldPermission()
    let model = makeModel(held: held)
    model.start()
    #expect(model.accessPermission == .notAsked)
    let check = Task { await model.refreshAccessPermission() }
    await settle()
    held.checks[0].resume(returning: nil)
    await check.value
    #expect(model.accessPermission == .notAsked)
}

@MainActor @Test func levelsChangedWhileDeniedStartOnALaterLaunchOnceAccessIsOn() async {
    let defaults = InMemoryPreferences()
    let denied = TestPermission(); denied.current = .denied
    let (first, _) = makeModel(store: makeStore(defaults: defaults, saved: ["Music": AppAdjustment(volume: 0.3)]), permission: denied)
    first.start()
    await first.enableAppLevels()
    #expect(first.state == .accessDenied)

    let allowed = TestPermission(); allowed.current = .allowed
    let (second, backend) = makeModel(store: makeStore(defaults: defaults), permission: allowed)
    second.start()
    await settle()
    #expect(second.state == .waitingForAudio && backend.enabled)
}
