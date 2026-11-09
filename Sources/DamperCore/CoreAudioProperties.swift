import CoreAudio
import Foundation

/// HAL access is confined to the control plane. No property access occurs inside the IOProc.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Marks this app's private aggregates. Discovery hides any device with this UID prefix.
    static let internalDeviceUIDPrefix = "damper.internal."
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioBackendError.operationFailed(operation, status) }
    }
    /// Removal succeeded, or the HAL no longer knows the object.
    static func isObjectGone(_ status: OSStatus) -> Bool {
        status == noErr || status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
    }
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                          initial: T) throws -> T {
        var a = address(selector, scope, element), value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, bytes.baseAddress!), "Read audio property")
        }
        guard size == MemoryLayout<T>.size else { throw AudioBackendError.unsupported("Audio property has an unexpected size.") }
        return value
    }
    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        try scalar(object, selector, scope: scope, initial: UInt32(0))
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var a = address(selector, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "Size audio object list")
        guard size <= 1_048_576, size % 4 == 0 else { throw AudioBackendError.unsupported("Invalid audio object list.") }
        if size == 0 { return [] }
        var result = [UInt32](repeating: 0, count: Int(size / 4))
        let capacity = size
        try result.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!), "Read audio object list")
        }
        guard size <= capacity, size % 4 == 0 else { throw AudioBackendError.unsupported("Audio object list changed during discovery.") }
        return Array(result.prefix(Int(size / 4)))
    }
    static func cf(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> CFTypeRef {
        var a = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        var reference: Unmanaged<CFTypeRef>?
        try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &reference), "Read audio object metadata")
        guard let reference else { throw AudioBackendError.unsupported("Missing audio object metadata.") }
        return reference.takeRetainedValue()
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        guard let result = try cf(object, selector) as? String else { throw AudioBackendError.unsupported("Invalid audio object name.") }
        return result
    }
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, value: T) throws {
        var a = address(selector, scope, element), copy = value
        try withUnsafeBytes(of: &copy) {
            try check(AudioObjectSetPropertyData(object, &a, 0, nil, UInt32($0.count), $0.baseAddress!), "Set audio property")
        }
    }
    static func settable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var a = address(selector, scope, element), result = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &a) &&
            AudioObjectIsPropertySettable(object, &a, &result) == noErr && result.boolValue
    }
    static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size), "Read channel layout size")
        guard size >= MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!, size <= 1_048_576 else {
            throw AudioBackendError.unsupported("Invalid device channel layout.")
        }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let capacity = size
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, memory), "Read device channel layout")
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard size <= capacity, header + count * MemoryLayout<AudioBuffer>.stride <= Int(size) else {
            throw AudioBackendError.unsupported("Invalid device buffer layout.")
        }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }
    static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }
    static func isPrivateAggregate(_ device: AudioObjectID) -> Bool {
        guard (try? uint(device, kAudioObjectPropertyClass)) == kAudioAggregateDeviceClassID else { return false }
        guard let composition = (try? cf(device, kAudioAggregateDevicePropertyComposition)) as? [String: Any] else { return true }
        return isPrivateComposition(composition)
    }
    /// The SDK defines a missing key as a device published to the entire system.
    static func isPrivateComposition(_ composition: [String: Any]) -> Bool {
        (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }
}
