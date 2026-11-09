import AppKit
import CoreAudio
import Foundation

@MainActor
public final class CoreAudioBackend: AudioBackend {
    public var onSnapshot: ((AudioSnapshot) -> Void)?
    public var onFailure: ((String) -> Void)?
    /// Queued HAL work of every pipeline, including ones already retired and still tearing down.
    private let pipelineWork = DispatchGroup()
    private let accessWork = DispatchQueue(label: "damper.audio-access", qos: .userInitiated)
    private var monitoring = false
    private var enabled = false
    private var requestedAccess = false
    private var sleeping = false
    private var desired: [String: AppAdjustment] = [:]
    private var clients: [DiscoveredClient] = []
    private var outputs: [AudioOutputSnapshot] = []
    private var defaultOutput: UInt32?
    private var listeners: [ListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var observers: [NSObjectProtocol] = []
    private let refreshes = RefreshScheduler(debounce: .milliseconds(35),
                                             retryDelays: [.milliseconds(250), .seconds(1), .seconds(3)])
    /// Output volume and mute change many times a second during a drag, and a full refresh is
    /// tens of milliseconds on the main actor, so these only re-read the levels.
    private let levelRefreshes = RefreshScheduler(debounce: .milliseconds(35), retryDelays: [])
    private var pipelines: [String: PipelineEntry] = [:]
    /// One serial queue per app. A replacement pipeline waits behind its predecessor's teardown, so a
    /// HAL call that blocks can't pile up pipelines for one app, and other apps never wait on it.
    /// Queues stay for the session, one per adjusted app, so an app that quits and comes back still
    /// waits behind its earlier teardown.
    private var pipelineQueues: [String: DispatchQueue] = [:]
    private var failures: [String: (AudioPipelineRequest, String)] = [:]
    private var refreshRetryPending = false
    private var outputUnsupportedReason: String?
    private var outputHogOwner: pid_t?
    private var accessState: AudioAccessState = .notRequested
    private var accessSession: AccessEntry?
    private var accessPrompt: CoreAudioAccessSession?
    private static let systemSelectors = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                                          kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted]

    public init() {
        refreshes.perform = { [weak self] in
            guard let self, self.monitoring else { return }
            try self.refresh()
        }
        refreshes.failed = { [weak self] error, final in self?.refreshFailed(error, final: final) }
        levelRefreshes.perform = { [weak self] in
            guard let self, self.monitoring else { return }
            self.refreshOutputLevels()
        }
    }

    isolated deinit { stop() }

    public func startMonitoring() throws {
        guard !monitoring else { publish(); return }
        monitoring = true
        for selector in Self.systemSelectors { listen(ListenerKey(AudioHAL.system, selector)) }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] { observe(name) }
        do { try refresh() }
        catch { stop(); throw error }
    }

    public func requestAccess() async throws {
        guard monitoring else { throw AudioBackendError.unsupported("Start audio discovery before requesting access.") }
        requestedAccess = true
        if accessState != .verified { accessState = .waitingForAudio }
        reconcileAccess(); publish()
    }

    /// Makes macOS ask for access now, even with nothing playing, by briefly reading every process
    /// without muting any. It has its own queue because a HAL start can wait a long time, and that
    /// must not hold up real access checks. It verifies nothing: silence looks the same either way.
    public func promptForAccess() {
        guard accessPrompt == nil, let processes = try? AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyProcessObjectList),
              !processes.isEmpty else { return }
        let session = CoreAudioAccessSession(processes: processes, queue: DispatchQueue(label: "damper.audio-access-prompt", qos: .userInitiated))
        accessPrompt = session
        session.start(stopOnceStarted: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.accessPrompt = nil }
        }
    }

    public func accessWasLost() {
        requestedAccess = false; accessState = .notRequested
        retireAccessSession(); reconcile(); publish()
    }

    public func setAdjustment(_ adjustment: AppAdjustment, for clientID: String) {
        desired[clientID] = adjustment
        // A gain change leaves a live pipeline's status as it was, so a slider tick costs no HAL reads.
        if let entry = pipelines[clientID], failures[clientID] == nil,
           CoreAudioBackendLogic.needsPipeline(adjustment, hasPipeline: true) {
            entry.pipeline.setGain(adjustment.effectiveGain); return
        }
        failures.removeValue(forKey: clientID)
        reconcileAccess(); reconcile(); publish()
    }
    public func removeAdjustment(for clientID: String) {
        desired.removeValue(forKey: clientID); failures.removeValue(forKey: clientID)
        retire(clientID); reconcileAccess(); reconcile(); publish()
    }
    public func setProcessingEnabled(_ enabled: Bool) throws {
        if enabled && !requestedAccess { throw AudioBackendError.unsupported("Request system audio access before enabling app levels.") }
        self.enabled = enabled
        failures.removeAll()
        if !enabled { retireAll() }
        reconcileAccess(); reconcile(); publish()
    }
    public func selectOutput(_ deviceID: UInt32) throws {
        // Reselecting the current output must not retire pipelines, which would unmute apps.
        guard try AudioHAL.uint(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice) != deviceID else { return }
        let current = try CoreAudioDiscovery.outputs()
        guard current.contains(where: { $0.id == deviceID }) else { throw AudioBackendError.unsupported("This output is no longer available.") }
        do { try AudioHAL.set(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice, value: deviceID) }
        catch { throw AudioBackendError.unsupported("macOS could not switch to this output.") }
        scheduleRefresh(invalidate: true)
    }
    public func setOutputVolume(_ volume: Double, for device: UInt32) throws {
        guard volume.isFinite else { throw AudioBackendError.unsupported("Output volume must be finite.") }
        guard try isLiveDefaultOutput(device) else { return }
        guard let control = OutputVolumeControl.discover(device: device) else {
            throw AudioBackendError.unsupported("This output has no supported writable volume control.")
        }
        try control.setVolume(volume, device: device)
        // Records what was written, so a matching read-back has nothing new to publish.
        noteOutputLevels(device, volume: Double(Float32(min(1, max(0, volume)))))
        levelRefreshes.signal()
    }
    public func setOutputMuted(_ muted: Bool, for device: UInt32) throws {
        guard try isLiveDefaultOutput(device) else { return }
        guard AudioHAL.settable(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) else {
            throw AudioBackendError.unsupported("This output has no writable hardware mute control.")
        }
        try AudioHAL.set(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
        noteOutputLevels(device, muted: muted)
        levelRefreshes.signal()
    }
    public func drain(timeout: TimeInterval) {
        let deadline = DispatchTime.now() + timeout
        let access = DispatchGroup()
        access.enter()
        accessWork.async { access.leave() }
        _ = access.wait(timeout: deadline)
        _ = pipelineWork.wait(timeout: deadline)
    }
    public func stop() {
        monitoring = false; enabled = false; requestedAccess = false; sleeping = false
        refreshRetryPending = false; outputUnsupportedReason = nil
        accessState = .notRequested
        refreshes.cancel(); levelRefreshes.cancel(); outputHogOwner = nil
        // Keep a cancelling session until its callback acknowledges cleanup. This
        // bounds outstanding starts even if a public HAL call is waiting on consent.
        retireAccessSession()
        accessPrompt?.stop(); accessPrompt = nil
        removeListeners { _ in true }
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
        retireAll(); failures.removeAll(); clients.removeAll(); outputs.removeAll(); defaultOutput = nil
        pipelineQueues.removeAll()
    }

    private struct PipelineEntry {
        let pipeline: CoreAudioPipeline
        let token: UUID
        var rendered = false
        var started = false
    }
    private struct AccessEntry {
        let session: CoreAudioAccessSession
        let token: UUID
        var stopping = false
    }
    private struct ListenerKey: Hashable {
        let object: UInt32
        let selector: UInt32
        let scope: UInt32
        let element: UInt32
        init(_ object: UInt32, _ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal,
             _ element: UInt32 = kAudioObjectPropertyElementMain) {
            self.object = object; self.selector = selector; self.scope = scope; self.element = element
        }
        var address: AudioObjectPropertyAddress { AudioHAL.address(selector, scope, element) }
    }
    private func isLiveDefaultOutput(_ device: UInt32) throws -> Bool {
        try AudioHAL.uint(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice) == device &&
            outputs.contains { $0.id == device } &&
            (try? AudioHAL.uint(device, kAudioDevicePropertyDeviceIsAlive)) == 1
    }
    private func observe(_ name: Notification.Name) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let name = note.name
            Task { @MainActor [weak self] in
                guard let self, self.monitoring else { return }
                if name == NSWorkspace.willSleepNotification {
                    self.sleeping = true; self.retireAll(); self.retireAccessSession(); self.publish(); return
                }
                if name == NSWorkspace.didWakeNotification { self.sleeping = false; self.failures.removeAll() }
                self.scheduleRefresh(invalidate: name == NSWorkspace.didWakeNotification)
            }
        }
        observers.append(token)
    }
    private func listen(_ key: ListenerKey) {
        guard listeners[key] == nil else { return }
        var address = key.address
        guard AudioObjectHasProperty(key.object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.monitoring else { return }
                if key.selector == kAudioHardwarePropertyServiceRestarted {
                    // Listener registrations belong to old object IDs after a service restart.
                    self.rebuildListenersAfterRestart(); return
                }
                if key.selector == kAudioDevicePropertyHogMode, key.object == self.defaultOutput {
                    self.outputHogMayHaveChanged(key.object)
                }
                if Self.levelSelectors.contains(key.selector) { self.levelRefreshes.signal(); return }
                // Notifications can repeat without a value change. Refresh revalidates the
                // full request; only a changed/unsafe route retires a healthy reader.
                self.scheduleRefresh()
            }
        }
        // Not every HAL object supports every notification; a refused listener is skipped.
        if AudioObjectAddPropertyListenerBlock(key.object, &address, .main, block) == noErr { listeners[key] = block }
    }
    private static let levelSelectors: Set<AudioObjectPropertySelector> = [
        kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute, OutputVolumeProperty.virtualMain.selector
    ]
    private func noteOutputLevels(_ device: UInt32, volume: Double? = nil, muted: Bool? = nil) {
        outputs = outputs.map { output in
            output.id == device ? output.withLevels(volume: volume ?? output.volume, muted: muted ?? output.muted) : output
        }
    }
    private func refreshOutputLevels() {
        let current = outputs.map { output in
            let levels = CoreAudioDiscovery.levels(device: output.id)
            return output.withLevels(volume: levels.volume, muted: levels.muted)
        }
        guard current != outputs else { return }
        outputs = current
        publish()
    }
    private func rebuildListenersAfterRestart() {
        retireAll(); failures.removeAll()
        retireAccessSession()
        if requestedAccess { accessState = .waitingForAudio }
        removeListeners { _ in true }
        for selector in Self.systemSelectors { listen(ListenerKey(AudioHAL.system, selector)) }
        scheduleRefresh()
    }
    /// A pipeline can fail because a hog started just after the route check, and an unchanged
    /// request would never retry on its own. Only a real change by another process clears
    /// failures, so a failing start cannot retry itself through a hog the HAL took for it.
    private func outputHogMayHaveChanged(_ device: UInt32) {
        let owner = CoreAudioBackendLogic.externalHogOwner(AudioHAL.hogModeOwner(device: device))
        guard owner != outputHogOwner else { return }
        outputHogOwner = owner
        failures.removeAll()
    }
    private func removeListeners(where shouldRemove: (ListenerKey) -> Bool) {
        for (key, block) in listeners where shouldRemove(key) {
            var address = key.address
            _ = AudioObjectRemovePropertyListenerBlock(key.object, &address, .main, block)
            listeners.removeValue(forKey: key)
        }
    }
    private func scheduleRefresh(invalidate: Bool = false) {
        guard monitoring else { return }
        if invalidate { retireAll(); retireAccessSession(); failures.removeAll() }
        refreshes.signal()
    }
    func refreshFailed(_ error: any Error, final: Bool) {
        refreshRetryPending = !final
        retireAll(); publish()
        guard final else { return }
        onFailure?(error.localizedDescription)
    }
    private func refresh() throws {
        outputs = try CoreAudioDiscovery.outputs()
        let selected = try AudioHAL.uint(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        let resolved = outputs.contains { $0.id == selected } ? selected : nil
        if defaultOutput != resolved { retireAll(); retireAccessSession(); failures.removeAll() }
        defaultOutput = resolved
        let processObjects = try AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyProcessObjectList)
        let previousClients = clients
        clients = CoreAudioDiscovery.clients(processObjects)
        for id in CoreAudioBackendLogic.idsThatStartedRunning(previous: previousClients, current: clients) {
            failures.removeValue(forKey: id)
        }
        updateListeners(processes: processObjects)
        refreshRetryPending = false
        reconcileAccess(); reconcile(); publish()
    }
    private func updateListeners(processes: [UInt32]) {
        var wanted: Set<ListenerKey> = []
        for selector in Self.systemSelectors { wanted.insert(ListenerKey(AudioHAL.system, selector)) }
        for process in processes {
            for selector in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyBundleID, kAudioProcessPropertyPID] {
                wanted.insert(ListenerKey(process, selector))
            }
            wanted.insert(ListenerKey(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput))
        }
        for output in outputs {
            for selector in [kAudioObjectPropertyName, kAudioObjectPropertyModelName, kAudioObjectPropertyManufacturer,
                             kAudioDevicePropertyModelUID, kAudioDevicePropertyTransportType, kAudioDevicePropertyIcon] {
                wanted.insert(ListenerKey(output.id, selector))
            }
            wanted.insert(ListenerKey(output.id, kAudioDevicePropertyDeviceIsAlive))
            wanted.insert(ListenerKey(output.id, kAudioDevicePropertyHogMode))
            wanted.insert(ListenerKey(output.id, kAudioDevicePropertyNominalSampleRate))
            wanted.insert(ListenerKey(output.id, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput))
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute,
                             kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration] {
                wanted.insert(ListenerKey(output.id, selector, kAudioObjectPropertyScopeOutput))
            }
            wanted.insert(ListenerKey(output.id, OutputVolumeProperty.virtualMain.selector, kAudioObjectPropertyScopeOutput,
                                      OutputVolumeProperty.virtualMain.element))
            let channelCount = (try? AudioHAL.channels(output.id, scope: kAudioObjectPropertyScopeOutput))?
                .reduce(UInt64(0)) { $0 + UInt64($1) } ?? 0
            if (1...UInt64(OutputVolumeControl.maxChannels)).contains(channelCount) {
                // Virtual-main values can be backed by channel controls. Listen to
                // those as well so hardware gestures and balance changes stay live.
                for element in 1...UInt32(channelCount) {
                    wanted.insert(ListenerKey(output.id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element))
                }
            }
            wanted.insert(ListenerKey(output.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput))
            for stream in (try? AudioHAL.objects(output.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? [] {
                wanted.insert(ListenerKey(stream, kAudioStreamPropertyVirtualFormat))
                wanted.insert(ListenerKey(stream, kAudioStreamPropertyPhysicalFormat))
            }
        }
        removeListeners { !wanted.contains($0) }
        for key in wanted { listen(key) }
    }
    /// Checked once per reconcile or publish, however many clients it covers.
    private func validatedRoute() -> Result<OutputRoute.Validated, any Error> {
        Result { try OutputRoute.validate(output: outputs.first { $0.id == defaultOutput }) }
    }
    private func reconcile() {
        let activeIDs = Set(clients.map(\.id))
        for id in Array(pipelines.keys) where !activeIDs.contains(id) { retire(id) }
        guard CoreAudioBackendLogic.pipelinesAllowed(monitoring: monitoring, enabled: enabled, sleeping: sleeping,
                                                     accessState: accessState) else { retireAll(); return }
        let route = validatedRoute()
        for client in clients {
            let adjustment = desired[client.id] ?? AppAdjustment()
            guard CoreAudioBackendLogic.needsPipeline(adjustment, hasPipeline: pipelines[client.id] != nil),
                  client.reason == nil, client.running else { retire(client.id); continue }
            do {
                let request = try OutputRoute.request(client: client, route: route)
                if let existing = pipelines[client.id], existing.pipeline.request == request {
                    existing.pipeline.setGain(adjustment.effectiveGain)
                    if !existing.rendered { pipelines[client.id]?.rendered = existing.pipeline.hasRendered }
                    continue
                }
                retire(client.id)
                // A route or process change replaces a pipeline only if the app still needs one, and a
                // request that already failed is not retried until something about it changes.
                guard adjustment.needsProcessing, failures[client.id]?.0 != request else { continue }
                let id = client.id, token = UUID()
                let queue = pipelineQueues[id] ?? DispatchQueue(label: "damper.pipeline", qos: .userInitiated)
                pipelineQueues[id] = queue
                let pipeline = CoreAudioPipeline(request: request, work: pipelineWork, queue: queue)
                failures.removeValue(forKey: id)
                pipelines[id] = PipelineEntry(pipeline: pipeline, token: token)
                watchStartup(id, token: token, request: request)
                pipeline.start(gain: adjustment.effectiveGain) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.pipelines[id]?.token == token else { return }
                        switch result {
                        case .success:
                            self.pipelines[id]?.started = true
                            self.inspect(id, token: token)
                        case let .failure(error):
                            self.failures[id] = (request, error.localizedDescription); self.retire(id)
                        }
                        self.publish()
                    }
                }
            } catch { retire(client.id) }
        }
    }
    /// Bounded render checks for a new pipeline, never a permanent meter or polling timer. Readings
    /// skip the pipeline's queue. A pipeline whose start is blocked in the HAL still reaches the
    /// deadline. Its teardown queues behind that start, so the failure text says only that
    /// processing did not start.
    private func watchStartup(_ id: String, token: UUID, request: AudioPipelineRequest) {
        Task { @MainActor [weak self] in
            for interval in CoreAudioBackendLogic.renderCheckIntervals {
                try? await Task.sleep(for: interval)
                guard let self, let entry = self.pipelines[id], entry.token == token,
                      !(entry.started && entry.rendered) else { return }
                self.inspect(id, token: token)
            }
            try? await Task.sleep(for: CoreAudioBackendLogic.renderDeadlineAfterLastCheck)
            guard let self else { return }
            self.inspect(id, token: token)
            guard let entry = self.pipelines[id], entry.token == token, !entry.rendered else { return }
            self.failures[id] = (request, CoreAudioBackendLogic.noRenderFailure)
            self.retire(id)
            self.publish()
        }
    }
    private func inspect(_ id: String, token: UUID) {
        // A fault reaches the backend through the pipeline's failure path, not this reading.
        guard let entry = pipelines[id], entry.token == token, !entry.rendered, entry.pipeline.hasRendered else { return }
        pipelines[id]?.rendered = true
        publish()
    }
    private func retire(_ id: String) { pipelines.removeValue(forKey: id)?.pipeline.stop() }
    private func retireAll() { for id in Array(pipelines.keys) { retire(id) } }
    private func retireAccessSession() {
        guard var entry = accessSession, !entry.stopping else { return }
        entry.stopping = true; accessSession = entry
        entry.session.stop()
    }
    private func reconcileAccess() {
        let shouldWait = monitoring && requestedAccess && enabled && !sleeping && accessState == .waitingForAudio
        let sources = shouldWait ? CoreAudioBackendLogic.accessSources(clients: clients, desired: desired) : []
        if let entry = accessSession {
            if !entry.stopping && (!shouldWait || entry.session.processes != sources) { retireAccessSession() }
            return
        }
        guard shouldWait, !sources.isEmpty else { return }
        let session = CoreAudioAccessSession(processes: sources, queue: accessWork)
        let token = UUID()
        accessSession = AccessEntry(session: session, token: token)
        session.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let entry = self.accessSession, entry.token == token else { return }
                self.accessSession = nil
                guard self.monitoring else { return }
                let (state, failure) = CoreAudioBackendLogic.applying(result, stopping: entry.stopping, sleeping: self.sleeping, to: .init(
                    enabled: self.enabled, requestedAccess: self.requestedAccess, accessState: self.accessState))
                self.enabled = state.enabled; self.requestedAccess = state.requestedAccess; self.accessState = state.accessState
                self.reconcileAccess(); self.reconcile(); self.publish()
                if let failure { self.onFailure?(failure) }
            }
        }
    }
    private func publish() {
        let route = validatedRoute()
        // While a failed refresh waits for its retry, a failed route check may be the outage
        // itself, so the last reason stands until a refresh succeeds or the retries run out.
        switch route {
        case .success: outputUnsupportedReason = nil
        case let .failure(error): if !refreshRetryPending { outputUnsupportedReason = error.localizedDescription }
        }
        let snapshots = clients.map { client -> AudioClientSnapshot in
            let pipeline = pipelines[client.id]
            return CoreAudioBackendLogic.clientSnapshot(client: client, adjustment: desired[client.id] ?? AppAdjustment(),
                enabled: enabled, sleeping: sleeping, accessState: accessState, routeRejection: routeRejection(client, route: route),
                failure: failures[client.id]?.1, hasPipeline: pipeline != nil,
                started: pipeline?.started ?? false, rendered: pipeline?.rendered ?? false)
        }
        onSnapshot?(AudioSnapshot(clients: snapshots, outputs: outputs, defaultOutputID: defaultOutput, accessState: accessState,
                                  outputUnsupportedReason: outputUnsupportedReason))
    }
    private func routeRejection(_ client: DiscoveredClient, route: Result<OutputRoute.Validated, any Error>) -> String? {
        guard client.reason == nil else { return nil }
        if case .failure = route { return outputUnsupportedReason }
        do { _ = try OutputRoute.request(client: client, route: route); return nil }
        catch { return error.localizedDescription }
    }
}
