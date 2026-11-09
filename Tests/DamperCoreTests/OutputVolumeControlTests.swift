import CoreAudio
import Foundation
import Testing
@testable import DamperCore

private let channelOne = OutputVolumeProperty(selector: kAudioDevicePropertyVolumeScalar, element: 1)
private let channelTwo = OutputVolumeProperty(selector: kAudioDevicePropertyVolumeScalar, element: 2)

/// Pure property-store tests; no device is opened and no system volume is changed.
private final class VolumePropertyStore: OutputVolumePropertyAccess {
    var channelCount: UInt64 = 2
    var values: [OutputVolumeProperty: Float32] = [:]
    var writable: Set<OutputVolumeProperty> = []
    var unreadable: Set<OutputVolumeProperty> = []
    var writes: [(OutputVolumeProperty, Float32)] = []
    var failingWrites: Set<Int> = []

    init(_ values: [OutputVolumeProperty: Float32] = [:]) {
        self.values = values
        writable = Set(values.keys)
    }
    func outputChannelCount() throws -> UInt64 { channelCount }
    func isSettable(_ property: OutputVolumeProperty) -> Bool { writable.contains(property) }
    func read(_ property: OutputVolumeProperty) throws -> Float32 {
        guard !unreadable.contains(property), let value = values[property] else {
            throw AudioBackendError.operationFailed("Read test control", 5)
        }
        return value
    }
    func write(_ value: Float32, to property: OutputVolumeProperty) throws {
        writes.append((property, value))
        if failingWrites.contains(writes.count) { throw AudioBackendError.operationFailed("Write test control", 6) }
        values[property] = value
    }
}

@Test func outputVolumePrefersWritableMainBeforeVirtualOrChannelControls() throws {
    let store = VolumePropertyStore([.main: 0.6, .virtualMain: 0.4, channelOne: 0.3, channelTwo: 0.2])
    let control = try #require(OutputVolumeControl.discover(access: store))
    #expect(control.property == .main && abs(control.volume - 0.6) < 0.000001)
    try control.setVolume(0.5, access: store)
    #expect(store.writes.count == 1 && store.writes[0].0 == .main)
    #expect(store.values[channelOne] == 0.3 && store.values[channelTwo] == 0.2)
}

@Test func outputVolumeUsesAdvertisedVirtualMainBeforeChannelFallback() throws {
    let store = VolumePropertyStore([.main: 0.6, .virtualMain: 0.4, channelOne: 0.3, channelTwo: 0.2])
    store.writable.remove(.main)
    let control = try #require(OutputVolumeControl.discover(access: store))
    #expect(control.property == .virtualMain)
    try control.setVolume(0.75, access: store)
    #expect(store.writes.count == 1 && store.writes[0].0 == .virtualMain)
    #expect(store.values[.virtualMain] == 0.75)
}

@Test func outputVolumeOffersNoRouteForChannelOnlyDevices() {
    let store = VolumePropertyStore([channelOne: 0.4, channelTwo: 0.2])
    #expect(OutputVolumeControl.discover(access: store) == nil)
    store.channelCount = 65
    #expect(OutputVolumeControl.discover(access: store) == nil)
    #expect(store.writes.isEmpty)
}

@Test func outputVolumeRejectsUnreadableOrInvalidControls() {
    let store = VolumePropertyStore([.main: 0.5])
    store.writable.remove(.main)
    #expect(OutputVolumeControl.discover(access: store) == nil)
    store.writable.insert(.main); store.unreadable.insert(.main)
    #expect(OutputVolumeControl.discover(access: store) == nil)
    store.unreadable.remove(.main)
    for value: Float32 in [.nan, .infinity, -0.1, 1.1] {
        store.values[.main] = value
        #expect(OutputVolumeControl.discover(access: store) == nil)
    }
    #expect(store.writes.isEmpty)
}

@Test func outputVolumeRejectsADeviceWithNoOutputChannels() throws {
    let store = VolumePropertyStore([.main: 0.5])
    let control = try #require(OutputVolumeControl.discover(access: store))
    store.channelCount = 0
    #expect(OutputVolumeControl.discover(access: store) == nil)
    #expect(throws: AudioBackendError.self) { try control.setVolume(0.8, access: store) }
    #expect(store.writes.isEmpty)
}

@Test func aLargeDeviceKeepsItsSingleVolumeControl() throws {
    let main = VolumePropertyStore([.main: 0.5])
    main.channelCount = 65
    let mainControl = try #require(OutputVolumeControl.discover(access: main))
    #expect(mainControl.property == .main)
    try mainControl.setVolume(0.25, access: main)
    #expect(main.values[.main] == 0.25)

    let virtual = VolumePropertyStore([.virtualMain: 0.5])
    virtual.channelCount = 128
    let virtualControl = try #require(OutputVolumeControl.discover(access: virtual))
    #expect(virtualControl.property == .virtualMain)
    try virtualControl.setVolume(0.25, access: virtual)
    #expect(virtual.values[.virtualMain] == 0.25)
}

@Test func outputVolumePrevalidatesAChangedControlBeforeWriting() throws {
    let store = VolumePropertyStore([.main: 0.4])
    let control = try #require(OutputVolumeControl.discover(access: store))
    store.writable.remove(.main)
    #expect(throws: AudioBackendError.self) { try control.setVolume(0.8, access: store) }
    #expect(store.writes.isEmpty)
}

@Test func outputVolumeWritesEvenWhenTheReadBackAlreadyMatches() throws {
    let store = VolumePropertyStore([.main: 0.4])
    let control = try #require(OutputVolumeControl.discover(access: store))
    try control.setVolume(0.4, access: store)
    try control.setVolume(0.4, access: store)
    #expect(store.writes.count == 2)
}

@Test func outputVolumeReportsAFailedWrite() throws {
    let store = VolumePropertyStore([.main: 0.4])
    let control = try #require(OutputVolumeControl.discover(access: store))
    store.failingWrites = [1]
    #expect(throws: AudioBackendError.operationFailed("Write test control", 6)) { try control.setVolume(0.8, access: store) }
    #expect(store.values[.main] == 0.4)
}

@Test func outputVolumeClampsFiniteTargetsAndRejectsNonfiniteBeforeWriting() throws {
    let store = VolumePropertyStore([.main: 0.5])
    let control = try #require(OutputVolumeControl.discover(access: store))
    for value in [Double.nan, .infinity, -.infinity] {
        #expect(throws: AudioBackendError.self) { try control.setVolume(value, access: store) }
    }
    #expect(store.writes.isEmpty)
    try control.setVolume(-5, access: store)
    #expect(store.values[.main] == 0)
    try control.setVolume(5, access: store)
    #expect(store.values[.main] == 1)
}
