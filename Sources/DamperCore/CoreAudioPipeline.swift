import CoreAudio
import AudioRealtime
import Foundation

struct AudioPipelineRequest: Equatable, Sendable {
    let processes: [UInt32]
    let bundleIDs: [String]
    let output: UInt32
    let outputUID: String
    let outputFormat: AudioPCMLayout
}

/// The main actor's way into a pipeline's audio-thread state: the gain to apply and whether the
/// callback has rendered. Neither waits behind HAL work on the pipeline's queue. The audio thread
/// never takes this lock, and teardown detaches the state before freeing it.
final class RealtimeHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var state: OpaquePointer? // guarded by lock
    private var gain: Float = 1 // guarded by lock

    var hasRendered: Bool { lock.withLock { state.map { AudioRealtimeHasRendered($0) } ?? false } }
    var currentGain: Float { lock.withLock { gain } }
    /// A gain set before the state exists is kept and applied when it's attached.
    func setGain(_ gain: Float) {
        lock.withLock { self.gain = gain; if let state { AudioRealtimeSetGain(state, gain) } }
    }
    func attach(_ state: OpaquePointer?) {
        lock.withLock { self.state = state; if let state { AudioRealtimeSetGain(state, gain) } }
    }
}

/// HAL setup and teardown run on the app's own serial queue, so a HAL call that blocks only
/// holds up this app. The only audio-thread accesses are C atomics and the immutable layout.
/// @unchecked is limited to this queue boundary and the handle's lock.
final class CoreAudioPipeline: @unchecked Sendable {
    let queue: DispatchQueue
    /// Every block this pipeline queues, so the backend can wait for teardown at quit.
    private let work: DispatchGroup
    private let cancellation = NSLock()
    private var cancelled = false // guarded by cancellation
    private var tap: AudioObjectID = 0 // queue-confined from here down
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var realtime: OpaquePointer?
    private var faultSource: DispatchSourceRead?
    private var faultReadFD: Int32 = -1
    private var faultWriteFD: Int32 = -1
    private var propertyListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let handle = RealtimeHandle()
    private static let gainRampSeconds = 0.005
    let request: AudioPipelineRequest

    init(request: AudioPipelineRequest, work: DispatchGroup,
         queue: DispatchQueue = DispatchQueue(label: "damper.pipeline", qos: .userInitiated)) {
        self.request = request; self.work = work; self.queue = queue
    }
    private var isCancelled: Bool { cancellation.withLock { cancelled } }
    var hasRendered: Bool { handle.hasRendered }

    private func run(_ block: @escaping @Sendable () -> Void) {
        work.enter()
        queue.async { block(); self.work.leave() }
    }

    func start(gain: Float, completion: @escaping @Sendable (Result<Void, AudioBackendError>) -> Void) {
        handle.setGain(gain)
        run { [self] in
            do {
                guard !isCancelled else { return }
                let ioProc = try prepare()
                try installFaultNotification(completion)
                try installPropertyNotifications(completion)
                guard !isCancelled else { teardown(); return }
                // Tap auto-start is off, because it can make this wait for the app's first audio.
                // This runs off the main actor, so a HAL call that does wait can't block the UI.
                try AudioHAL.check(AudioDeviceStart(aggregate, ioProc), "Start application audio")
                if isCancelled { teardown(); return }
                completion(.success(()))
            } catch {
                teardown()
                if !isCancelled {
                    completion(.failure(error as? AudioBackendError ?? .unsupported(error.localizedDescription)))
                }
            }
        }
    }
    func setGain(_ gain: Float) { handle.setGain(gain) }
    func stop() {
        cancellation.withLock { cancelled = true }
        run { [self] in teardown() }
    }

    private func prepare() throws -> AudioDeviceIOProcID {
        // Reject hardware with inputs before building anything. Asking for zero input channels in
        // the composition doesn't prove a driver left out its microphone streams.
        guard try AudioHAL.validatedPlaybackFormat(device: request.output) == request.outputFormat else {
            throw AudioBackendError.unsupported("The output format changed before audio could start.")
        }
        let description = CATapDescription()
        description.name = "Damper application tap"
        description.processes = request.processes
        description.bundleIDs = request.bundleIDs
        description.isProcessRestoreEnabled = true
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = false
        description.deviceUID = request.outputUID
        description.stream = 0
        // No original playback is suppressed until an IOProc actually reads this tap.
        description.muteBehavior = .mutedWhenTapped
        try AudioHAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create application tap")
        let tapUID = try AudioHAL.string(tap, kAudioTapPropertyUID)
        let tapFormat = try AudioPCMLayout(AudioHAL.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()))
        _ = try tapFormat.mapping(to: request.outputFormat)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Damper private playback",
            kAudioAggregateDeviceUIDKey: "\(AudioHAL.internalDeviceUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: request.outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: request.outputUID,
                                                     kAudioSubDeviceInputChannelsKey: 0]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                              kAudioSubTapDriftCompensationKey: 1]]
        ]
        try AudioHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create private playback device")
        // Check that the only hardware subdevice has no inputs and the only tap is ours, so every
        // input stream comes from the tap. Input buffers are never picked by position.
        let subdevices = try AudioHAL.objects(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)
        guard subdevices.count == 1,
              try AudioHAL.string(subdevices[0], kAudioDevicePropertyDeviceUID) == request.outputUID,
              try AudioHAL.channels(subdevices[0], scope: kAudioObjectPropertyScopeInput).allSatisfy({ $0 == 0 }),
              let taps = try AudioHAL.cf(aggregate, kAudioAggregateDevicePropertyTapList) as? [String], taps == [tapUID] else {
            throw AudioBackendError.unsupported("Cannot establish a tap-only input path. Original playback is unchanged.")
        }
        let inputs = try AudioHAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = try AudioHAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs.count == 1, outputs.count == 1,
              try AudioHAL.uint(outputs[0], kAudioStreamPropertyStartingChannel) == 1 else {
            throw AudioBackendError.unsupported("This app’s audio or this output has a stream layout that isn’t supported.")
        }
        let input = try AudioPCMLayout(AudioHAL.format(inputs[0]))
        let output = try AudioPCMLayout(AudioHAL.format(outputs[0]))
        // StartingChannel is a property element number, not a buffer index, and it need not be 1
        // for the tap. The checks above and the buffer configuration below settle the mapping.
        guard input == tapFormat, output == request.outputFormat,
              try AudioHAL.channels(aggregate, scope: kAudioObjectPropertyScopeInput) == input.buffers,
              try AudioHAL.channels(aggregate, scope: kAudioObjectPropertyScopeOutput) == output.buffers else {
            throw AudioBackendError.unsupported("This app’s audio and this output have channel layouts that don’t match.")
        }
        let rate = try AudioHAL.scalar(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        guard rate == input.sampleRate else { throw AudioBackendError.unsupported("This app’s audio and this output have different sample rates.") }
        guard let state = AudioRealtimeCreate(try input.mapping(to: output), handle.currentGain, UInt32(rate * Self.gainRampSeconds)) else {
            throw AudioBackendError.unsupported("Cannot allocate the application gain processor.")
        }
        realtime = state
        handle.attach(state)
        try AudioHAL.check(AudioDeviceCreateIOProcID(aggregate, AudioRealtimeIOProc, UnsafeMutableRawPointer(state), &ioProc), "Create audio callback")
        guard let ioProc else { throw AudioBackendError.unsupported("Missing audio callback.") }
        var enabled: UInt32 = 1
        try AudioHAL.check(AudioRealtimeConfigureStreams(aggregate, ioProc, kAudioObjectPropertyScopeInput, 1, &enabled), "Select tap input stream")
        try AudioHAL.check(AudioRealtimeConfigureStreams(aggregate, ioProc, kAudioObjectPropertyScopeOutput, 1, &enabled), "Select hardware output stream")
        return ioProc
    }

    private func installFaultNotification(_ completion: @escaping @Sendable (Result<Void, AudioBackendError>) -> Void) throws {
        (faultReadFD, faultWriteFD) = try AudioHAL.makeNonblockingPipe(purpose: "audio failure notification")
        AudioRealtimeSetFaultFileDescriptor(realtime, faultWriteFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: faultReadFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.isCancelled else { return }
            var byte: UInt8 = 0
            _ = read(self.faultReadFD, &byte, 1)
            self.teardown()
            completion(.failure(.unsupported("The audio callback received an unsupported buffer layout. Original playback has been restored.")))
        }
        let readDescriptor = faultReadFD
        source.setCancelHandler { close(readDescriptor) }
        source.resume(); faultSource = source
    }

    private func installPropertyNotifications(_ completion: @escaping @Sendable (Result<Void, AudioBackendError>) -> Void) throws {
        var properties: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (tap, AudioHAL.address(kAudioTapPropertyFormat)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyDeviceIsAlive)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyNominalSampleRate)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)),
            (aggregate, AudioHAL.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
        ]
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            for stream in try AudioHAL.objects(aggregate, kAudioDevicePropertyStreams, scope: scope) {
                properties.append((stream, AudioHAL.address(kAudioStreamPropertyVirtualFormat)))
            }
        }
        for (object, originalAddress) in properties {
            var address = originalAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.isCancelled, self.aggregate != 0 else { return }
                self.teardown()
                completion(.failure(.unsupported("The tap or playback layout changed. Original playback has been restored.")))
            }
            try AudioHAL.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Watch playback layout")
            propertyListeners.append((object, address, block))
        }
    }

    private func teardown() {
        for (object, originalAddress, block) in propertyListeners {
            var address = originalAddress
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        propertyListeners.removeAll()
        let readerDetached = AudioHAL.destroyTapReader(tap: tap, aggregate: aggregate, ioProc: ioProc)
        ioProc = nil; aggregate = 0; tap = 0
        handle.attach(nil)
        if readerDetached {
            // Cancelling the source closes the read end.
            if let faultSource { faultSource.cancel(); self.faultSource = nil; faultReadFD = -1 }
            if faultWriteFD >= 0 { close(faultWriteFD); faultWriteFD = -1 }
            if let realtime { AudioRealtimeDestroy(realtime); self.realtime = nil }
        } else {
            // If the HAL refuses both callback removal and aggregate destruction, it may still
            // call into this memory. Keep the small state and its pipe until the process exits,
            // rather than risk a use-after-free or reusing a descriptor a live callback holds.
            faultSource?.setCancelHandler {}; faultSource?.cancel(); faultSource = nil
            faultReadFD = -1; faultWriteFD = -1; realtime = nil
        }
    }
}

