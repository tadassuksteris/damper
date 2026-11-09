import CoreAudio
import Foundation

/// Text for one tap-only reader. The access session's strings can reach the user.
struct TapOnlyReaderLabels {
    let tapName: String
    let createTap: String
    let deviceName: String
    let deviceUIDKind: String
    let createDevice: String
    let containsHardware: String
    let invalidInput: String
}

/// Setup and teardown shared by every reader of a process tap.
extension AudioHAL {
    /// Closes both descriptors itself when configuration fails.
    static func makeNonblockingPipe(purpose: String) throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw AudioBackendError.unsupported("Cannot create the \(purpose) pipe.") }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptors[0]); close(descriptors[1])
            throw AudioBackendError.unsupported("Cannot configure the \(purpose) pipe.")
        }
        return (descriptors[0], descriptors[1])
    }

    /// Creates a nonmuting mixdown tap and a private aggregate holding only that tap, then proves
    /// the tap is the sole input. On a throw, `tap` and `aggregate` still hold whatever was created
    /// so the caller's teardown destroys it.
    static func createTapOnlyReader(processes: [AudioObjectID], labels: TapOnlyReaderLabels,
                                    tap: inout AudioObjectID, aggregate: inout AudioObjectID) throws {
        let description = CATapDescription()
        description.name = labels.tapName
        description.isPrivate = true; description.isExclusive = false
        description.processes = processes
        description.isMixdown = true; description.isMono = false
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), labels.createTap)
        let uid = try string(tap, kAudioTapPropertyUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: labels.deviceName,
            kAudioAggregateDeviceUIDKey: "\(internalDeviceUIDPrefix)\(labels.deviceUIDKind).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), labels.createDevice)
        guard try objects(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList).isEmpty,
              try channels(aggregate, scope: kAudioObjectPropertyScopeOutput).allSatisfy({ $0 == 0 }) else {
            throw AudioBackendError.unsupported(labels.containsHardware)
        }
        let tapFormat = try AudioPCMLayout(scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()))
        let inputs = try objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        guard inputs.count == 1, try AudioPCMLayout(format(inputs[0])) == tapFormat,
              try channels(aggregate, scope: kAudioObjectPropertyScopeInput) == tapFormat.buffers else {
            throw AudioBackendError.unsupported(labels.invalidInput)
        }
    }

    /// Stops and destroys a reader's HAL objects: IOProc, then aggregate, then tap. Stops even after
    /// a failed start; no reader may survive a partial setup. Returns `readerDetached`, and the caller
    /// must keep its C state and pipe alive when that is false. Pass each object at most once.
    static func destroyTapReader(tap: AudioObjectID, aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID?) -> Bool {
        var ioProcRemoval: OSStatus?
        if let ioProc {
            _ = AudioDeviceStop(aggregate, ioProc)
            ioProcRemoval = AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        let aggregateRemoval = aggregate != 0 ? AudioHardwareDestroyAggregateDevice(aggregate) : nil
        if tap != 0 { _ = AudioHardwareDestroyProcessTap(tap) }
        return readerDetached(ioProcRemoval: ioProcRemoval, aggregateRemoval: aggregateRemoval)
    }

    /// No callback can still use the reader's C state once no IOProc existed, or removing the IOProc
    /// or its aggregate reported the object gone. A nil status means that object never existed.
    static func readerDetached(ioProcRemoval: OSStatus?, aggregateRemoval: OSStatus?) -> Bool {
        (ioProcRemoval.map(isObjectGone) ?? true) || (aggregateRemoval.map(isObjectGone) ?? false)
    }
}
