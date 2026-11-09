import CoreAudio
import Foundation
import Testing
@testable import DamperCore

/// Pure route property store; no device is opened and the HAL is never called.
private final class RouteStore: OutputRouteAccess {
    static let device: AudioObjectID = 7
    static let stream: AudioObjectID = 70

    var objectClassID: AudioClassID = kAudioDeviceClassID
    var outputStreams = [RouteStore.stream]
    var inputStreams: [AudioObjectID] = []
    var format = pcm()
    var rate: Float64 = 48_000
    var preferred: [UInt32] = [1, 2]
    var start: UInt32 = 1
    var outputChannels: [UInt32] = [2]
    var inputChannels: [UInt32] = []
    var hogOwner: pid_t? = -1
    var reads: [String] = []

    func objectClass() throws -> AudioClassID { reads.append("class"); return objectClassID }
    func streams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        reads.append(scope == kAudioObjectPropertyScopeInput ? "inputStreams" : "outputStreams")
        return scope == kAudioObjectPropertyScopeInput ? inputStreams : outputStreams
    }
    func streamFormat(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription { reads.append("format"); return format }
    func nominalRate() throws -> Float64 { reads.append("rate"); return rate }
    func preferredStereo() throws -> [UInt32] { reads.append("preferredStereo"); return preferred }
    func startingChannel(_ stream: AudioObjectID) throws -> UInt32 { reads.append("start"); return start }
    func channels(scope: AudioObjectPropertyScope) throws -> [UInt32] {
        reads.append(scope == kAudioObjectPropertyScopeInput ? "inputChannels" : "outputChannels")
        return scope == kAudioObjectPropertyScopeInput ? inputChannels : outputChannels
    }
    func hogModeOwner() -> pid_t? { reads.append("hog"); return hogOwner }
}

private func client(running: Bool = true, devices: Set<UInt32> = [RouteStore.device], reason: String? = nil) -> DiscoveredClient {
    DiscoveredClient(id: "org.example.player", name: "Player", bundleID: "org.example.player", url: nil, objects: [1],
                     bundleIDs: ["org.example.player"], running: running, devices: devices, reason: reason)
}

private let output = AudioOutputSnapshot(id: RouteStore.device, uid: "output-uid", name: "Output")

private func route(_ store: RouteStore) -> Result<OutputRoute.Validated, any Error> {
    Result { try OutputRoute.validate(output: output) { _ in store } }
}

private func validate(_ store: RouteStore, client subject: DiscoveredClient = client()) throws -> AudioPipelineRequest {
    try OutputRoute.request(client: subject, route: route(store))
}

private func rejection(_ store: RouteStore, client subject: DiscoveredClient = client()) -> String? {
    do { _ = try validate(store, client: subject); return nil }
    catch { return error.localizedDescription }
}

// MARK: - Access gate

@Test func pipelinesRequireVerifiedAccessWhileEnabledMonitoringAndAwake() {
    #expect(CoreAudioBackendLogic.pipelinesAllowed(monitoring: true, enabled: true, sleeping: false, accessState: .verified))
    for state: AudioAccessState in [.notRequested, .waitingForAudio, .denied] {
        #expect(!CoreAudioBackendLogic.pipelinesAllowed(monitoring: true, enabled: true, sleeping: false, accessState: state))
    }
    #expect(!CoreAudioBackendLogic.pipelinesAllowed(monitoring: false, enabled: true, sleeping: false, accessState: .verified))
    #expect(!CoreAudioBackendLogic.pipelinesAllowed(monitoring: true, enabled: false, sleeping: false, accessState: .verified))
    #expect(!CoreAudioBackendLogic.pipelinesAllowed(monitoring: true, enabled: true, sleeping: true, accessState: .verified))
}

// MARK: - Access results

private let waiting = CoreAudioBackendLogic.AccessFlags(enabled: true, requestedAccess: true, accessState: .waitingForAudio)

@Test func observedSignalVerifiesAccessOnlyWhileStillWanted() {
    let verified = CoreAudioBackendLogic.applying(.observedSignal, stopping: false, sleeping: false, to: waiting)
    #expect(verified.state.accessState == .verified && verified.failure == nil)

    var paused = waiting; paused.enabled = false
    #expect(CoreAudioBackendLogic.applying(.observedSignal, stopping: false, sleeping: false, to: paused).state == paused)
    #expect(CoreAudioBackendLogic.applying(.observedSignal, stopping: false, sleeping: true, to: waiting).state == waiting)
    #expect(CoreAudioBackendLogic.applying(.observedSignal, stopping: true, sleeping: false, to: waiting).state == waiting)
    var unrequested = waiting; unrequested.requestedAccess = false
    #expect(CoreAudioBackendLogic.applying(.observedSignal, stopping: false, sleeping: false, to: unrequested).state == unrequested)
}

@Test func accessFailureDisablesLevelsAndOnlyOrdinaryFailuresAreReported() {
    let denied = CoreAudioBackendLogic.applying(.failed(.permissionDenied), stopping: false, sleeping: false, to: waiting)
    #expect(denied.state == .init(enabled: false, requestedAccess: false, accessState: .denied) && denied.failure == nil)

    let failed = CoreAudioBackendLogic.applying(.failed(.unsupported("No reader.")), stopping: false, sleeping: false, to: waiting)
    #expect(failed.state == .init(enabled: false, requestedAccess: true, accessState: .notRequested) && failed.failure == "No reader.")

    #expect(CoreAudioBackendLogic.applying(.cancelled, stopping: false, sleeping: false, to: waiting).state == waiting)
    let stopping = CoreAudioBackendLogic.applying(.failed(.permissionDenied), stopping: true, sleeping: false, to: waiting)
    #expect(stopping.state == waiting && stopping.failure == nil)
}

// MARK: - Route validation

@Test func aSupportedRouteProducesARequestWithItsFormat() throws {
    let store = RouteStore()
    let result = try validate(store)
    #expect(result.output == RouteStore.device && result.outputUID == "output-uid" && result.processes == [1])
    #expect(result.outputFormat == (try AudioPCMLayout(pcm())))
    #expect(store.reads == ["class", "hog", "outputStreams", "format", "rate", "preferredStereo", "inputChannels",
                            "start", "inputStreams", "outputChannels"])
}

@Test func aMissingOutputStopsBeforeAnyDeviceRead() {
    let store = RouteStore()
    do {
        _ = try OutputRoute.validate(output: nil) { _ in store }
        Issue.record("A missing output must be rejected.")
    } catch { #expect(error.localizedDescription == "No system output is available.") }
    #expect(store.reads.isEmpty)
}

@Test func aClientReasonOutranksARejectedRoute() {
    let aggregate = RouteStore()
    aggregate.objectClassID = kAudioAggregateDeviceClassID
    #expect(rejection(aggregate, client: client(reason: "Not attributed.")) == "Not attributed.")
}

@Test func aRouteIsValidatedOnceHoweverManyClientsUseIt() throws {
    let store = RouteStore()
    let validated = route(store)
    let readsAfterValidation = store.reads.count
    for _ in 0..<5 { _ = try OutputRoute.request(client: client(), route: validated) }
    #expect(store.reads.count == readsAfterValidation)
}

@Test func aggregateOutputIsRejectedBeforeAnyOtherRead() {
    let store = RouteStore()
    store.objectClassID = kAudioAggregateDeviceClassID
    #expect(rejection(store)?.contains("Aggregate and multi-output") == true)
    #expect(store.reads == ["class"])
}

@Test func aRejectedOutputOutranksAClientOnAnotherDevice() {
    let aggregate = RouteStore()
    aggregate.objectClassID = kAudioAggregateDeviceClassID
    #expect(rejection(aggregate, client: client(devices: [99]))?.contains("Aggregate and multi-output") == true)

    let duplex = RouteStore()
    duplex.inputChannels = [1]
    #expect(rejection(duplex, client: client(devices: [99]))?.contains("microphone") == true)
}

@Test func onlyARunningClientOnAnotherDeviceIsRejected() {
    #expect(rejection(RouteStore(), client: client(running: true, devices: [99])) == "Plays to another output. Can’t adjust it here.")
    #expect(rejection(RouteStore(), client: client(running: true, devices: [RouteStore.device, 99])) == "Plays to another output. Can’t adjust it here.")
    #expect(rejection(RouteStore(), client: client(running: false, devices: [99])) == nil)
}

@Test func inputStreamsAreRejected() {
    let store = RouteStore()
    store.inputStreams = [71]
    #expect(rejection(store)?.contains("input streams") == true)
}

@Test func inputChannelsWithoutInputStreamsAreRejected() {
    let store = RouteStore()
    store.inputChannels = [0, 1]
    #expect(rejection(store)?.contains("microphone") == true)
}

@Test func aDuplexDeviceReportsItsMicrophoneInputsRatherThanItsInputStreams() {
    let store = RouteStore()
    store.inputStreams = [71]
    store.inputChannels = [1]
    #expect(rejection(store)?.contains("microphone") == true)
}

@Test func zeroInputChannelsAreAccepted() {
    let store = RouteStore()
    store.inputChannels = [0]
    #expect(rejection(store) == nil)
}

@Test func multipleOutputStreamsGetTheirOwnMessage() {
    let store = RouteStore()
    store.outputStreams = [70, 71]
    #expect(rejection(store) == "This output has more than one stream, which isn’t supported.")
}

@Test func swappedPreferredStereoIsRejected() {
    let store = RouteStore()
    store.preferred = [2, 1]
    #expect(rejection(store) == "This output’s stereo channel order isn’t supported.")
}

@Test func aMonoDeviceNeverReadsPreferredStereo() {
    let store = RouteStore()
    store.format = pcm(channels: 1)
    store.outputChannels = [1]
    #expect(rejection(store) == nil)
    #expect(!store.reads.contains("preferredStereo"))
}

@Test func routeRejectsRateChannelLayoutAndOffsetMismatches() {
    let rate = RouteStore()
    rate.rate = 44_100
    #expect(rejection(rate) == "This output’s sample rate doesn’t match its stream.")
    let layout = RouteStore()
    layout.outputChannels = [1, 1]
    #expect(rejection(layout) == "This output’s channel layout doesn’t match its stream.")
    let offset = RouteStore()
    offset.start = 3
    #expect(rejection(offset)?.contains("channel layout") == true)
}

@Test func anotherProcessHoldingHogModeRejectsTheRoute() {
    let store = RouteStore()
    store.hogOwner = getpid() &+ 1
    #expect(rejection(store) == "Another app has exclusive use of this output.")
    for free: pid_t? in [-1, getpid(), nil] {
        store.hogOwner = free
        #expect(rejection(store) == nil)
    }
}

@Test func playbackRecheckAppliesEveryDeviceCheckWithoutAClient() throws {
    #expect(try OutputRoute.validatedPlaybackFormat(access: RouteStore()) == AudioPCMLayout(pcm()))
    let aggregate = RouteStore()
    aggregate.objectClassID = kAudioAggregateDeviceClassID
    #expect(throws: AudioBackendError.self) { try OutputRoute.validatedPlaybackFormat(access: aggregate) }
    let duplex = RouteStore()
    duplex.inputChannels = [1]
    #expect(throws: AudioBackendError.self) { try OutputRoute.validatedPlaybackFormat(access: duplex) }
}

// MARK: - Snapshot mapping

private func snapshot(client subject: DiscoveredClient = client(), adjustment: AppAdjustment = AppAdjustment(volume: 0.5),
                      enabled: Bool = true, sleeping: Bool = false, accessState: AudioAccessState = .verified,
                      routeRejection: String? = nil, failure: String? = nil,
                      hasPipeline: Bool = false, started: Bool = false, rendered: Bool = false) -> AudioClientSnapshot {
    CoreAudioBackendLogic.clientSnapshot(client: subject, adjustment: adjustment, enabled: enabled, sleeping: sleeping,
        accessState: accessState, routeRejection: routeRejection, failure: failure,
        hasPipeline: hasPipeline, started: started, rendered: rendered)
}

@Test func snapshotReasonPrecedenceIsPausedSleepAccessIOThenFailure() {
    let idle = client(running: false)
    #expect(snapshot(client: idle, enabled: false, sleeping: true, accessState: .waitingForAudio, failure: "Broken.").unavailableReason == "App levels are paused.")
    #expect(snapshot(client: idle, sleeping: true, accessState: .waitingForAudio, failure: "Broken.").unavailableReason == "Audio processing is suspended during sleep.")
    #expect(snapshot(client: idle, accessState: .waitingForAudio, failure: "Broken.").unavailableReason == "Waiting for audio access. Your saved level is kept.")
    #expect(snapshot(client: idle, failure: "Broken.").unavailableReason == "Waiting for output IO. Your saved level is kept.")
    let failed = snapshot(failure: "Broken.", hasPipeline: true, started: true, rendered: true)
    #expect(failed.unavailableReason == "Broken." && !failed.isControllable && !failed.isAdjustmentApplied)
}

@Test func snapshotIsAppliedOnlyOnceStartedAndRendered() {
    #expect(snapshot(hasPipeline: true, started: true, rendered: true).isAdjustmentApplied)
    for (started, rendered) in [(false, false), (true, false), (false, true)] {
        let value = snapshot(hasPipeline: true, started: started, rendered: rendered)
        #expect(!value.isAdjustmentApplied && value.isAdjustmentPending)
        #expect(value.unavailableReason == "Waiting for the application audio callback. Access and playback are not yet verified.")
    }
}

@Test func snapshotOfARunningAppWithNoPipelineAndNoFailureUsesPlainWordingAndIsNotPending() {
    let value = snapshot()
    #expect(!value.isAdjustmentApplied && !value.isAdjustmentPending && value.isControllable)
    #expect(value.unavailableReason == "Reconnecting. Your saved level is kept.")
}

@Test func snapshotWithoutAnAdjustmentIsAppliedAndUnaffectedByBackendState() {
    let value = snapshot(adjustment: AppAdjustment(), enabled: false, sleeping: true, accessState: .denied, failure: "Broken.")
    #expect(value.isAdjustmentApplied && value.isControllable && value.unavailableReason == nil && !value.isAdjustmentPending)
    #expect(snapshot(adjustment: AppAdjustment(volume: 0.5, ignored: true), enabled: false).isAdjustmentApplied)
}

@Test func snapshotKeepsTheClientAndRouteReasonsWhileNotControllable() {
    let unattributed = snapshot(client: client(reason: "Not attributed."), adjustment: AppAdjustment())
    #expect(!unattributed.isControllable && unattributed.unavailableReason == "Not attributed.")
    let rejected = snapshot(adjustment: AppAdjustment(), routeRejection: "Duplex.")
    #expect(!rejected.isControllable && rejected.unavailableReason == "Duplex.")
    let adjusted = snapshot(routeRejection: "Duplex.")
    #expect(!adjusted.isControllable && adjusted.unavailableReason == "Duplex." && !adjusted.isAdjustmentApplied)
}

@Test func snapshotIsPendingOnlyWhileAPipelineOrAccessWaitCanStillApplyIt() {
    #expect(snapshot(accessState: .waitingForAudio).isAdjustmentPending)
    #expect(snapshot(hasPipeline: true).isAdjustmentPending)
    #expect(!snapshot().isAdjustmentPending)
    #expect(!snapshot(enabled: false, hasPipeline: true).isAdjustmentPending)
    #expect(!snapshot(sleeping: true, hasPipeline: true).isAdjustmentPending)
    #expect(!snapshot(client: client(running: false), hasPipeline: true).isAdjustmentPending)
}

@Test func aRejectionKeepsItsReasonInsteadOfAWaitingOrPausedOne() {
    let idle = client(running: false)
    let expectations: [AudioClientSnapshot] = [
        snapshot(client: idle, routeRejection: "Duplex."),
        snapshot(client: idle, accessState: .waitingForAudio, routeRejection: "Duplex."),
        snapshot(client: idle, sleeping: true, routeRejection: "Duplex."),
        snapshot(enabled: false, routeRejection: "Duplex."),
        snapshot(enabled: false, accessState: .denied, routeRejection: "Duplex.")
    ]
    for value in expectations {
        #expect(value.unavailableReason == "Duplex." && !value.isControllable && !value.isAdjustmentPending)
    }
    let unattributed = snapshot(client: client(running: false, reason: "Not attributed."), enabled: false)
    #expect(unattributed.unavailableReason == "Not attributed." && !unattributed.isAdjustmentPending)
}

@Test func aRejectedRouteIsNeverReportedAsAppliedEvenWithALivePipeline() {
    let value = snapshot(routeRejection: "Duplex.", hasPipeline: true, started: true, rendered: true)
    #expect(!value.isAdjustmentApplied)
}

@Test func onlyAFailedPipelineOnAUsableRouteCanRetry() {
    #expect(snapshot(failure: "Broken.").canRetry)
    #expect(snapshot(failure: CoreAudioBackendLogic.noRenderFailure).canRetry)
    #expect(!snapshot().canRetry)
    #expect(!snapshot(routeRejection: "Duplex.").canRetry)
    #expect(!snapshot(routeRejection: "Duplex.", failure: "Broken.").canRetry)
    #expect(!snapshot(client: client(reason: "Not attributed."), failure: "Broken.").canRetry)
    #expect(!snapshot(client: client(running: false), failure: "Broken.").canRetry)
    #expect(!snapshot(enabled: false, failure: "Broken.").canRetry)
    #expect(!snapshot(adjustment: AppAdjustment(), failure: "Broken.").canRetry)
}

@Test func onlyAValidatedApplicationHasAStableIdentity() {
    #expect(snapshot().hasStableIdentity)
    let unattributed = DiscoveredClient(id: "unattributed:48213", name: "afplay", bundleID: nil, url: nil, objects: [1],
                                        bundleIDs: [], running: true, devices: [RouteStore.device], reason: "Not attributed.")
    #expect(!snapshot(client: unattributed).hasStableIdentity)
}

// MARK: - Failure clearing and startup deadline

private func named(_ id: String, running: Bool) -> DiscoveredClient {
    DiscoveredClient(id: id, name: id, bundleID: id, url: nil, objects: [1], bundleIDs: [], running: running, devices: [], reason: nil)
}

@Test func onlyAClientThatStartsOutputIOGetsItsFailureCleared() {
    let previous = [named("stopped", running: false), named("playing", running: true)]
    let current = [named("stopped", running: true), named("playing", running: true), named("new", running: true), named("idle", running: false)]
    #expect(CoreAudioBackendLogic.idsThatStartedRunning(previous: previous, current: current) == ["stopped", "new"])
    #expect(CoreAudioBackendLogic.idsThatStartedRunning(previous: current, current: current).isEmpty)
}

@Test func theNoRenderDeadlineFollowsEveryRenderCheck() {
    let deadline = CoreAudioBackendLogic.renderCheckIntervals.reduce(.zero, +) + CoreAudioBackendLogic.renderDeadlineAfterLastCheck
    #expect(deadline >= .seconds(8) && deadline <= .seconds(10))
    #expect(CoreAudioBackendLogic.renderDeadlineAfterLastCheck > .zero)
}

// MARK: - Access sources

@Test func theAccessReaderSkipsIgnoredAndIdleApps() {
    var ignored = named("ignored", running: true); ignored.objects = [5]
    var playing = named("playing", running: true); playing.objects = [3, 2]
    var idle = named("idle", running: false); idle.objects = [4]
    let desired = ["ignored": AppAdjustment(ignored: true), "playing": AppAdjustment(volume: 0.5)]
    #expect(CoreAudioBackendLogic.accessSources(clients: [ignored, playing, idle], desired: desired) == [2, 3])
    #expect(CoreAudioBackendLogic.accessSources(clients: [ignored], desired: desired).isEmpty)
}

// MARK: - Output listing

@Test func theOutputMenuDropsADeviceThatCannotBeDefaultUnlessItIsTheDefault() {
    #expect(CoreAudioBackendLogic.isOfferedAsOutput(7, selected: 8, canBeDefault: 1))
    #expect(!CoreAudioBackendLogic.isOfferedAsOutput(7, selected: 8, canBeDefault: 0))
    #expect(CoreAudioBackendLogic.isOfferedAsOutput(7, selected: 7, canBeDefault: 0))
    #expect(CoreAudioBackendLogic.isOfferedAsOutput(7, selected: nil, canBeDefault: nil))
}

@Test func onlyAnExplicitKeyMarksAnAggregatePrivate() {
    #expect(!AudioHAL.isPrivateComposition([:]))
    #expect(!AudioHAL.isPrivateComposition([kAudioAggregateDeviceIsPrivateKey: 0]))
    #expect(AudioHAL.isPrivateComposition([kAudioAggregateDeviceIsPrivateKey: 1]))
}

// MARK: - Status text

@Test func printableHALStatusesReadAsFourCharacterCodes() {
    #expect(AudioBackendError.operationFailed("Create tap", kAudioHardwareNotReadyError).localizedDescription == "Create tap failed ('nrdy').")
    #expect(AudioBackendError.operationFailed("Create tap", 42).localizedDescription == "Create tap failed (42).")
    #expect(AudioBackendError.operationFailed("Create tap", -1).localizedDescription == "Create tap failed (-1).")
}

// MARK: - Quit

@MainActor @Test func drainReturnsPromptlyWhenNoTeardownIsQueued() {
    let backend = CoreAudioBackend()
    let start = ContinuousClock.now
    backend.drain(timeout: 5)
    #expect(ContinuousClock.now - start < .seconds(4))
}

// MARK: - Tap reader teardown rule

@Test func objectGoneTreatsOnlySuccessAndBadObjectStatusesAsRemoved() {
    #expect(AudioHAL.isObjectGone(noErr))
    #expect(AudioHAL.isObjectGone(kAudioHardwareBadObjectError))
    #expect(AudioHAL.isObjectGone(kAudioHardwareBadDeviceError))
    #expect(!AudioHAL.isObjectGone(kAudioHardwareUnspecifiedError))
    #expect(!AudioHAL.isObjectGone(kAudioHardwareIllegalOperationError))
}

@Test func readerStateMayOnlyBeFreedOnceNoCallbackCanStillUseIt() {
    let refused = kAudioHardwareUnspecifiedError
    #expect(AudioHAL.readerDetached(ioProcRemoval: nil, aggregateRemoval: nil))
    #expect(AudioHAL.readerDetached(ioProcRemoval: nil, aggregateRemoval: refused))
    #expect(AudioHAL.readerDetached(ioProcRemoval: noErr, aggregateRemoval: refused))
    #expect(AudioHAL.readerDetached(ioProcRemoval: refused, aggregateRemoval: noErr))
    #expect(AudioHAL.readerDetached(ioProcRemoval: refused, aggregateRemoval: kAudioHardwareBadObjectError))
    #expect(!AudioHAL.readerDetached(ioProcRemoval: refused, aggregateRemoval: nil))
    #expect(!AudioHAL.readerDetached(ioProcRemoval: refused, aggregateRemoval: refused))
}

@Test func destroyingAReaderWithNoObjectsReportsItDetached() {
    #expect(AudioHAL.destroyTapReader(tap: 0, aggregate: 0, ioProc: nil))
}

@Test func notificationPipeIsNonblockingOnBothEnds() throws {
    let descriptors = try AudioHAL.makeNonblockingPipe(purpose: "test")
    defer { close(descriptors.read); close(descriptors.write) }
    #expect(fcntl(descriptors.read, F_GETFL) & O_NONBLOCK != 0)
    #expect(fcntl(descriptors.write, F_GETFL) & O_NONBLOCK != 0)
}

@Test func anAppBackAtFullLevelKeepsItsPipelineUntilItStopsPlaying() {
    let full = AppAdjustment(), lowered = AppAdjustment(volume: 0.5), muted = AppAdjustment(muted: true)
    #expect(CoreAudioBackendLogic.needsPipeline(lowered, hasPipeline: false))
    #expect(CoreAudioBackendLogic.needsPipeline(muted, hasPipeline: false))
    #expect(!CoreAudioBackendLogic.needsPipeline(full, hasPipeline: false))
    #expect(CoreAudioBackendLogic.needsPipeline(full, hasPipeline: true))
    #expect(!CoreAudioBackendLogic.needsPipeline(AppAdjustment(volume: 0.5, ignored: true), hasPipeline: true))
    #expect(!CoreAudioBackendLogic.needsPipeline(AppAdjustment(ignored: true), hasPipeline: true))
}
