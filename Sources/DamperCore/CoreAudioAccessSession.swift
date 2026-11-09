import AudioRealtime
import CoreAudio
import Foundation

enum AudioAccessSessionResult: Sendable {
    case observedSignal, cancelled, failed(AudioBackendError)
}

/// One nonmuting, tap-only reader while access is unverified. The callback emits
/// one pipe byte on first signal; silence has no deadline and is never an error.
final class CoreAudioAccessSession: @unchecked Sendable {
    private let queue: DispatchQueue
    private let cancellation = NSLock()
    private var cancelled = false
    private var finished = false // all remaining fields belong to queue
    private var completion: (@Sendable (AudioAccessSessionResult) -> Void)?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var state: OpaquePointer?
    private var signalSource: DispatchSourceRead?
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    let processes: [UInt32]
    private static let readerLabels = TapOnlyReaderLabels(
        tapName: "Damper audio access", createTap: "Request system audio access",
        deviceName: "Damper private audio access", deviceUIDKind: "access", createDevice: "Create audio access device",
        containsHardware: "The audio access device unexpectedly contains hardware.",
        invalidInput: "The audio access reader does not expose the expected Float32 tap input.")

    init(processes: [UInt32], queue: DispatchQueue) {
        self.processes = processes
        self.queue = queue
    }

    private var isCancelled: Bool { cancellation.withLock { cancelled } }

    /// With `stopOnceStarted`, the reader exists only to make macOS decide on access: it ends as
    /// soon as the HAL start returns, instead of waiting for a signal.
    func start(stopOnceStarted: Bool = false, completion: @escaping @Sendable (AudioAccessSessionResult) -> Void) {
        queue.async { [self] in
            self.completion = completion
            do {
                guard !isCancelled else { finish(.cancelled); return }
                try prepare()
                guard !isCancelled else { finish(.cancelled); return }
                guard let ioProc else { throw AudioBackendError.unsupported("The audio access callback was not created.") }
                // This can wait on macOS asking for consent. The UI is already showing a waiting
                // state, and playback setup and teardown run on each pipeline's own queue.
                try AudioHAL.check(AudioDeviceStart(aggregate, ioProc), "Start system audio access")
                if isCancelled || stopOnceStarted { finish(.cancelled) }
            } catch {
                finish(isCancelled ? .cancelled : .failed(Self.accessError(error)))
            }
        }
    }

    func stop() {
        cancellation.withLock { cancelled = true }
        queue.async { [self] in finish(.cancelled) }
    }

    /// This reader names no device and has no subdevice, so a permission status cannot mean
    /// another app holds the output. It is the only place that status means denied access.
    static func accessError(_ error: any Error) -> AudioBackendError {
        guard let error = error as? AudioBackendError else { return .unsupported(error.localizedDescription) }
        if case let .operationFailed(_, status) = error, status == kAudioDevicePermissionsError { return .permissionDenied }
        return error
    }

    private func prepare() throws {
        guard !processes.isEmpty, let state = AudioAccessProbeCreate() else {
            throw AudioBackendError.unsupported("Cannot prepare system audio access.")
        }
        self.state = state
        (readFD, writeFD) = try AudioHAL.makeNonblockingPipe(purpose: "audio access notification")
        AudioAccessProbeSetSignalFileDescriptor(state, writeFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            var byte: UInt8 = 0
            _ = read(self.readFD, &byte, 1)
            self.finish(self.isCancelled ? .cancelled : .observedSignal)
        }
        let descriptor = readFD
        source.setCancelHandler { close(descriptor) }
        source.resume(); signalSource = source

        try AudioHAL.createTapOnlyReader(processes: processes, labels: Self.readerLabels, tap: &tap, aggregate: &aggregate)
        try AudioHAL.check(AudioDeviceCreateIOProcID(aggregate, AudioAccessProbeIOProc, UnsafeMutableRawPointer(state), &ioProc), "Create audio access callback")
    }

    private func finish(_ result: AudioAccessSessionResult) {
        guard !finished else { return }
        finished = true
        let detached = AudioHAL.destroyTapReader(tap: tap, aggregate: aggregate, ioProc: ioProc)
        ioProc = nil; aggregate = 0; tap = 0
        if detached {
            // Cancelling the source closes the read end.
            if let signalSource { signalSource.cancel(); self.signalSource = nil; readFD = -1 }
            if writeFD >= 0 { close(writeFD); writeFD = -1 }
            if let state { AudioAccessProbeDestroy(state); self.state = nil }
        } else {
            // A broken HAL must not retain a pointer into freed state or a reused FD.
            signalSource?.setCancelHandler {}; signalSource?.cancel(); signalSource = nil
            readFD = -1; writeFD = -1; state = nil
        }
        let notify = completion; completion = nil
        notify?(result)
    }
}
