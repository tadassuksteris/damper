#if DEBUG
import AudioToolbox
import CoreAudio

/// Helpers for the opt-in audio check. Only reads hardware settings.
enum AudioCheckSupport {
    static let absent = "absent"

    /// The check compares this before and after running, so every output control an app could
    /// move is recorded. Channels catch balance changes on routes with no main-element volume.
    static func hardwareState() throws -> [String: String] {
        let device = try AudioHAL.uint(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        let scope = kAudioObjectPropertyScopeOutput
        var state = try controlState(
            channelCount: AudioHAL.channels(device, scope: scope).reduce(0) { $0 + Int($1) },
            exists: { selector, element in
                var address = AudioHAL.address(selector, scope, element)
                return AudioObjectHasProperty(device, &address)
            },
            volume: { selector, element in try AudioHAL.scalar(device, selector, scope: scope, element: element, initial: Float32(0)) },
            mute: { try AudioHAL.uint(device, kAudioDevicePropertyMute, scope: scope) })
        state["deviceID"] = String(device)
        state["uid"] = try AudioHAL.string(device, kAudioDevicePropertyDeviceUID)
        return state
    }

    /// A control that does not exist is recorded as absent. A failed read of one that does throws.
    static func controlState(channelCount: Int,
                             exists: (AudioObjectPropertySelector, AudioObjectPropertyElement) -> Bool,
                             volume: (AudioObjectPropertySelector, AudioObjectPropertyElement) throws -> Float32,
                             mute: () throws -> UInt32) throws -> [String: String] {
        let main = kAudioObjectPropertyElementMain
        func level(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) throws -> String {
            exists(selector, element) ? String(try volume(selector, element)) : absent
        }
        var state = [
            "volume": try level(kAudioDevicePropertyVolumeScalar, main),
            "virtualMainVolume": try level(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, main),
            "muted": exists(kAudioDevicePropertyMute, main) ? String(try mute()) : absent
        ]
        for channel in 0..<min(channelCount, OutputVolumeControl.maxChannels) {
            state["channel\(channel + 1)Volume"] = try level(kAudioDevicePropertyVolumeScalar, UInt32(channel + 1))
        }
        return state
    }

    /// Damper's private devices. Only this process can see them, so after a pause there should be none.
    static func privateDevices() throws -> [AudioObjectID] {
        try AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyDevices).filter {
            (try? AudioHAL.string($0, kAudioDevicePropertyDeviceUID))?.hasPrefix(AudioHAL.internalDeviceUIDPrefix) == true
        }
    }

    /// Denied access never reports through onFailure, so the check looks at both.
    static func blockingError(accessState: AudioAccessState, failure: String?) -> AudioBackendError? {
        if accessState == .denied { return .permissionDenied }
        return failure.map(AudioBackendError.unsupported)
    }
}
#endif
