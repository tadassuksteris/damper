#if DEBUG
import AudioToolbox
import CoreAudio
import Testing
@testable import DamperCore

private func state(channelCount: Int = 2, existing: Set<UInt32>, volume: Float32 = 0.5,
                   channelVolume: Float32 = 0.25) throws -> [String: String] {
    try AudioCheckSupport.controlState(
        channelCount: channelCount,
        exists: { selector, element in
            element == kAudioObjectPropertyElementMain ? existing.contains(selector) : existing.contains(element)
        },
        volume: { _, element in element == kAudioObjectPropertyElementMain ? volume : channelVolume },
        mute: { 1 })
}

@Test func hardwareStateRecordsMissingMainControlsAsAbsentOnChannelOnlyRoutes() throws {
    let airPodsStyle = try state(existing: [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 1, 2])
    #expect(airPodsStyle == ["volume": AudioCheckSupport.absent, "virtualMainVolume": "0.5",
                             "muted": AudioCheckSupport.absent, "channel1Volume": "0.25", "channel2Volume": "0.25"])
    let noControls = try state(existing: [])
    #expect(noControls["channel2Volume"] == AudioCheckSupport.absent)
    #expect(noControls["volume"] == AudioCheckSupport.absent)
}

@Test func hardwareStateNoticesAChangedChannelVolume() throws {
    let existing: Set<UInt32> = [1, 2]
    #expect(try state(existing: existing, channelVolume: 0.25) != state(existing: existing, channelVolume: 0.5))
}

@Test func hardwareStateLetsAFailedReadOfAnExistingControlThrow() {
    let failure = AudioBackendError.operationFailed("Read audio property", kAudioHardwareNotReadyError)
    #expect(throws: failure) {
        try AudioCheckSupport.controlState(channelCount: 0, exists: { _, _ in true }, volume: { _, _ in throw failure }, mute: { 0 })
    }
    #expect(throws: failure) {
        try AudioCheckSupport.controlState(channelCount: 0, exists: { selector, _ in selector == kAudioDevicePropertyMute },
                                           volume: { _, _ in 0 }, mute: { throw failure })
    }
}

@Test func hardwareStateHandlesNoChannelsAndCapsLargeDevices() throws {
    let channelKey: (String) -> Bool = { $0.hasPrefix("channel") }
    #expect(try state(channelCount: 0, existing: []).keys.filter(channelKey).isEmpty)
    let large = try state(channelCount: 512, existing: [64, 65])
    #expect(large.keys.filter(channelKey).count == OutputVolumeControl.maxChannels)
    #expect(large["channel64Volume"] == "0.25")
    #expect(large["channel65Volume"] == nil)
}

@Test func audioChecksFailFastOnDenialAndOnBackendFailure() {
    #expect(AudioCheckSupport.blockingError(accessState: .waitingForAudio, failure: nil) == nil)
    #expect(AudioCheckSupport.blockingError(accessState: .verified, failure: nil) == nil)
    #expect(AudioCheckSupport.blockingError(accessState: .denied, failure: nil) == .permissionDenied)
    #expect(AudioCheckSupport.blockingError(accessState: .denied, failure: "Reader failed.") == .permissionDenied)
    #expect(AudioCheckSupport.blockingError(accessState: .verified, failure: "Reader failed.") == .unsupported("Reader failed."))
}

@MainActor @Test func integrationCheckExpectationsFollowTheGainCurve() {
    let half = AppAdjustment(volume: 0.5), lowered = AppAdjustment(volume: 0.4), muted = AppAdjustment(volume: 0.5, muted: true)
    // Fixture B plays at twice A's level, so with four times its power.
    func ratio(_ a: AppAdjustment, _ b: AppAdjustment) -> Double {
        AudioIntegrationCheck.expectedRatio(a, b, baseline: half, powerA: 1, powerB: 4)
    }
    #expect(ratio(half, half) == 1)
    #expect(abs(ratio(muted, half) - 0.8.squareRoot()) < 1e-12)
    #expect(ratio(muted, muted) == 0)
    // An adjustment that reached the other fixture must fail its step.
    for (a, b) in [(muted, half), (muted, lowered), (half, lowered)] {
        #expect(!AudioIntegrationCheck.matches(ratio(b, a), expected: ratio(a, b)))
    }
    // A step that plays both fixtures must fail if either one is silent, or the check would pass on a broken pipeline.
    let bothLevels = ratio(half, lowered)
    #expect(!AudioIntegrationCheck.matches(ratio(half, muted), expected: bothLevels))
    #expect(!AudioIntegrationCheck.matches(ratio(muted, lowered), expected: bothLevels))
    #expect(AudioIntegrationCheck.matches(bothLevels * 1.01, expected: bothLevels))
    #expect(AudioIntegrationCheck.matches(0, expected: 0))
    #expect(!AudioIntegrationCheck.matches(0.01, expected: 0))
}
#endif
