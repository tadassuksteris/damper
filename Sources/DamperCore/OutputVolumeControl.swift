import AudioToolbox
import CoreAudio
import Foundation

/// A volume property on the output scope. Input controls are never read or changed here.
struct OutputVolumeProperty: Hashable, Sendable {
    let selector: AudioObjectPropertySelector
    let element: AudioObjectPropertyElement

    static let main = Self(selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
    static let virtualMain = Self(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  element: kAudioObjectPropertyElementMain)
}

protocol OutputVolumePropertyAccess {
    func outputChannelCount() throws -> UInt64
    func isSettable(_ property: OutputVolumeProperty) -> Bool
    func read(_ property: OutputVolumeProperty) throws -> Float32
    func write(_ value: Float32, to property: OutputVolumeProperty) throws
}

/// A discovered single-control hardware volume path. Discovery only reads; writes revalidate
/// the live control. Per-channel scalars are never used: the HAL does not guarantee read-backs
/// are current, so balance computed from them could drift, and virtual-main already keeps it.
struct OutputVolumeControl {
    /// Channel-volume listeners cover devices up to this size. A virtual-main control on a larger
    /// device updates only through its own listener and refreshes.
    static let maxChannels = 64

    let property: OutputVolumeProperty
    let volume: Double

    static func discover(device: AudioObjectID) -> Self? {
        discover(access: LiveOutputVolumeAccess(device: device))
    }

    static func discover(access: any OutputVolumePropertyAccess) -> Self? {
        guard let count = try? access.outputChannelCount(), count > 0 else { return nil }
        for property in [OutputVolumeProperty.main, .virtualMain] {
            if let value = try? level(property, access: access) {
                return Self(property: property, volume: Double(value))
            }
        }
        return nil
    }

    func setVolume(_ value: Double, device: AudioObjectID) throws {
        try setVolume(value, access: LiveOutputVolumeAccess(device: device))
    }

    /// Writes on every call. A read-back the HAL has not caught up on must not skip a real change.
    func setVolume(_ value: Double, access: any OutputVolumePropertyAccess) throws {
        guard value.isFinite else { throw AudioBackendError.unsupported("Output volume must be finite.") }
        guard try access.outputChannelCount() > 0 else {
            throw AudioBackendError.unsupported("The output channel layout cannot be controlled safely.")
        }
        _ = try Self.level(property, access: access)
        try access.write(Float32(min(1, max(0, value))), to: property)
    }

    private static func level(_ property: OutputVolumeProperty, access: any OutputVolumePropertyAccess) throws -> Float32 {
        guard access.isSettable(property) else {
            throw AudioBackendError.unsupported("The output volume control is no longer writable.")
        }
        let value = try access.read(property)
        guard value.isFinite, (0...1).contains(value) else {
            throw AudioBackendError.unsupported("The output reported an invalid volume value.")
        }
        return value
    }
}

private struct LiveOutputVolumeAccess: OutputVolumePropertyAccess {
    let device: AudioObjectID

    func outputChannelCount() throws -> UInt64 {
        try AudioHAL.channels(device, scope: kAudioObjectPropertyScopeOutput).reduce(UInt64(0)) { $0 + UInt64($1) }
    }
    func isSettable(_ property: OutputVolumeProperty) -> Bool {
        AudioHAL.settable(device, property.selector, scope: kAudioObjectPropertyScopeOutput, element: property.element)
    }
    func read(_ property: OutputVolumeProperty) throws -> Float32 {
        try AudioHAL.scalar(device, property.selector, scope: kAudioObjectPropertyScopeOutput,
                            element: property.element, initial: Float32(0))
    }
    func write(_ value: Float32, to property: OutputVolumeProperty) throws {
        try AudioHAL.set(device, property.selector, scope: kAudioObjectPropertyScopeOutput,
                         element: property.element, value: value)
    }
}
