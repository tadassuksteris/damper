import AudioRealtime
import CoreAudio
import Foundation
import Testing
@testable import DamperCore

private func setSize(_ buffers: TestAudioBuffers, _ index: Int, _ bytes: UInt32) {
    UnsafeMutableAudioBufferListPointer(buffers.list)[index].mDataByteSize = bytes
}
private func setAbsent(_ buffers: TestAudioBuffers, _ index: Int) {
    UnsafeMutableAudioBufferListPointer(buffers.list)[index].mData = nil
}

@Test func realtimeMapsInterleavedStereoToPlanarWithoutSwappingChannels() throws {
    let input = TestAudioBuffers(channels: [2], frames: 3), output = TestAudioBuffers(channels: [1, 1], frames: 3, fill: 99)
    let values: [Float] = [0.2, -0.4, 0.6, -0.8, 1, -1]
    for i in values.indices { input.samples[0][i] = values[i] }
    let mapping = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm(planar: true)))
    let state = try #require(AudioRealtimeCreate(mapping, 0.5, 0)); defer { AudioRealtimeDestroy(state) }
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0.1, 0.3, 0.5], [-0.2, -0.4, -0.5]])
    #expect(AudioRealtimeHasRendered(state)); #expect(!AudioRealtimeHasFault(state))
}
@Test func realtimeMapsPlanarStereoToInterleavedAndHonorsReversedBufferMapping() throws {
    let input = TestAudioBuffers(channels: [1, 1], frames: 2), output = TestAudioBuffers(channels: [2], frames: 2)
    input.samples[0][0] = 0.25; input.samples[0][1] = 0.5
    input.samples[1][0] = -0.25; input.samples[1][1] = -0.5
    var mapping = try AudioPCMLayout(pcm(planar: true)).mapping(to: AudioPCMLayout(pcm()))
    mapping.inputBuffer = (1, 0)
    let state = try #require(AudioRealtimeCreate(mapping, 1, 0)); defer { AudioRealtimeDestroy(state) }
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[-0.25, 0.25, -0.5, 0.5]])
}
@Test func realtimeRampsPerFrameAcrossBuffersAndReachesExactZero() throws {
    let input = TestAudioBuffers(channels: [2], frames: 2, fill: 1), output = TestAudioBuffers(channels: [2], frames: 2)
    let mapping = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let state = try #require(AudioRealtimeCreate(mapping, 1, 4)); defer { AudioRealtimeDestroy(state) }
    AudioRealtimeSetGain(state, 0)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0.75, 0.75, 0.5, 0.5]])
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0.25, 0.25, 0, 0]])
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0, 0, 0, 0]])
    AudioRealtimeSetGain(state, 1)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0.25, 0.25, 0.5, 0.5]])
    // Retarget from the current gain, without a discontinuous reset to unity.
    AudioRealtimeSetGain(state, 0)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0.375, 0.375, 0.25, 0.25]])
}
@Test func realtimeMonoClampsPCMAndRejectsNonfiniteGainWithoutSpikes() throws {
    let input = TestAudioBuffers(channels: [1], frames: 7), output = TestAudioBuffers(channels: [1], frames: 7)
    let samples: [Float] = [.nan, .infinity, -.infinity, 100, -100, 0.25, -0.25]
    for i in samples.indices { input.samples[0][i] = samples[i] }
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let state = try #require(AudioRealtimeCreate(mapping, 4, 0)); defer { AudioRealtimeDestroy(state) }
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values == [[0, 0, 0, 1, -1, 0.25, -0.25]])
    for gain: Float in [.nan, .infinity, -.infinity, -1, 0] {
        AudioRealtimeSetGain(state, gain)
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        #expect(output.values[0].allSatisfy { $0 == 0 })
    }
}
@Test func realtimeMalformedBuffersFaultAndNeverReplayStaleData() throws {
    let mono = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let interleaved = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let planar = try AudioPCMLayout(pcm(planar: true)).mapping(to: AudioPCMLayout(pcm(planar: true)))
    let noChange: (TestAudioBuffers, TestAudioBuffers) -> Void = { _, _ in }
    let cases: [(String, AudioRealtimeLayout, [UInt32], [UInt32], (TestAudioBuffers, TestAudioBuffers) -> Void)] = [
        ("extra input buffer", mono, [1, 1], [1], noChange),
        ("extra output buffer", mono, [1], [1, 1], noChange),
        ("missing planar input buffer", planar, [1], [1, 1], noChange),
        ("missing planar output buffer", planar, [1, 1], [1], noChange),
        ("input channel metadata", interleaved, [2], [2], { input, _ in input.list.pointee.mBuffers.mNumberChannels = 1 }),
        ("output channel metadata", interleaved, [2], [2], { _, output in output.list.pointee.mBuffers.mNumberChannels = 1 }),
        ("unequal planar buffers", planar, [1, 1], [1, 1], { input, output in
            setSize(input, 0, 4); setSize(output, 0, 4)
        }),
        ("misaligned sizes on both sides", interleaved, [2], [2], { input, output in
            setSize(input, 0, 12); setSize(output, 0, 12)
        }),
        ("misaligned input size", interleaved, [2], [2], { input, output in
            setSize(input, 0, 12); setSize(output, 0, 8)
        }),
        ("misaligned output size", interleaved, [2], [2], { input, output in
            setSize(input, 0, 8); setSize(output, 0, 12)
        }),
        ("partial input sample", interleaved, [2], [2], { input, _ in setSize(input, 0, 3) }),
        ("fewer output frames than input", interleaved, [2], [2], { _, output in setSize(output, 0, 8) })
    ]
    for (label, mapping, inputChannels, outputChannels, mutate) in cases {
        let state = try #require(AudioRealtimeCreate(mapping, 1, 0)); defer { AudioRealtimeDestroy(state) }
        let input = TestAudioBuffers(channels: inputChannels, frames: 2, fill: 1)
        let output = TestAudioBuffers(channels: outputChannels, frames: 2, fill: 1)
        mutate(input, output)
        #expect(!AudioRealtimeProcess(state, input.list, output.list), "\(label)")
        #expect(AudioRealtimeHasFault(state), "\(label)")
        #expect(!AudioRealtimeHasRendered(state), "\(label)")
        #expect(output.declaredAreZero, "\(label)")
    }
}
@Test func realtimeCreateRejectsEachInvalidLayoutField() throws {
    let interleaved = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let planarToInterleaved = try AudioPCMLayout(pcm(planar: true)).mapping(to: AudioPCMLayout(pcm()))
    let cases: [(String, AudioRealtimeLayout, (inout AudioRealtimeLayout) -> Void)] = [
        ("first input buffer", interleaved, { $0.inputBuffer = (1, 0) }),
        ("second input buffer", interleaved, { $0.inputBuffer = (0, 1) }),
        ("first output buffer", interleaved, { $0.outputBuffer = (1, 0) }),
        ("second output buffer", interleaved, { $0.outputBuffer = (0, 1) }),
        ("first input channel", interleaved, { $0.inputChannel = (2, 1) }),
        ("second input channel", interleaved, { $0.inputChannel = (0, 2) }),
        ("first output channel", interleaved, { $0.outputChannel = (2, 1) }),
        ("second output channel", interleaved, { $0.outputChannel = (0, 2) }),
        ("duplicate output channel", interleaved, { $0.outputChannel = (0, 0) }),
        ("zero input stride", interleaved, { $0.inputStride = 0 }),
        ("large input stride", interleaved, { $0.inputStride = 3 }),
        ("zero output stride", interleaved, { $0.outputStride = 0 }),
        ("large output stride", interleaved, { $0.outputStride = 3 }),
        ("zero input buffers", interleaved, { $0.inputBufferCount = 0 }),
        ("many input buffers", interleaved, { $0.inputBufferCount = 3 }),
        ("zero output buffers", interleaved, { $0.outputBufferCount = 0 }),
        ("many output buffers", interleaved, { $0.outputBufferCount = 3 }),
        ("zero channels", interleaved, { $0.channels = 0 }),
        // This base passes the per-channel checks if channel index 2 is ever read.
        ("three channels", planarToInterleaved, { $0.channels = 3 })
    ]
    for (label, base, mutate) in cases {
        let valid = try #require(AudioRealtimeCreate(base, 1, 0), "\(label)")
        AudioRealtimeDestroy(valid)
        var mapping = base
        mutate(&mapping)
        #expect(AudioRealtimeCreate(mapping, 1, 0) == nil, "\(label)")
    }
}
@Test func realtimeAbsentAndEmptyStreamsStaySilentWithoutFault() throws {
    let descriptors = try AudioHAL.makeNonblockingPipe(purpose: "test")
    defer { close(descriptors.read); close(descriptors.write) }
    let interleaved = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let planar = try AudioPCMLayout(pcm(planar: true)).mapping(to: AudioPCMLayout(pcm(planar: true)))
    let cases: [(String, AudioRealtimeLayout, [UInt32], (TestAudioBuffers, TestAudioBuffers) -> Void)] = [
        ("null input", interleaved, [2], { input, _ in setAbsent(input, 0) }),
        ("null output", interleaved, [2], { _, output in setAbsent(output, 0) }),
        ("null planar input", planar, [1, 1], { input, _ in setAbsent(input, 1) }),
        ("null planar output", planar, [1, 1], { _, output in setAbsent(output, 1) }),
        ("empty input", interleaved, [2], { input, _ in setSize(input, 0, 0) }),
        ("empty planar input", planar, [1, 1], { input, _ in setSize(input, 1, 0) })
    ]
    for (label, mapping, channels, mutate) in cases {
        let state = try #require(AudioRealtimeCreate(mapping, 1, 0)); defer { AudioRealtimeDestroy(state) }
        AudioRealtimeSetFaultFileDescriptor(state, descriptors.write)
        let input = TestAudioBuffers(channels: channels, frames: 512, fill: 1)
        let output = TestAudioBuffers(channels: channels, frames: 512, fill: 1)
        mutate(input, output)
        #expect(!AudioRealtimeProcess(state, input.list, output.list), "\(label)")
        #expect(!AudioRealtimeHasFault(state), "\(label)")
        #expect(!AudioRealtimeHasRendered(state), "\(label)")
        #expect(output.declaredAreZero, "\(label)")
        var byte: UInt8 = 0
        #expect(read(descriptors.read, &byte, 1) == -1, "\(label)")
        #expect(errno == EAGAIN, "\(label)")
    }
}
@Test func realtimeRendersAgainAfterAnEmptyInputCallback() throws {
    let input = TestAudioBuffers(channels: [2], frames: 512, fill: 1), output = TestAudioBuffers(channels: [2], frames: 512, fill: 1)
    let mapping = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let state = try #require(AudioRealtimeCreate(mapping, 0.5, 0)); defer { AudioRealtimeDestroy(state) }
    setSize(input, 0, 0)
    #expect(!AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values[0].allSatisfy { $0 == 0 })
    setSize(input, 0, 512 * 2 * 4)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values[0].allSatisfy { $0 == 0.5 })
    #expect(AudioRealtimeHasRendered(state)); #expect(!AudioRealtimeHasFault(state))
}
@Test func realtimeZeroFrameCallbackSucceedsWithoutRendering() throws {
    let input = TestAudioBuffers(channels: [2], frames: 0), output = TestAudioBuffers(channels: [2], frames: 0)
    let mapping = try AudioPCMLayout(pcm()).mapping(to: AudioPCMLayout(pcm()))
    let state = try #require(AudioRealtimeCreate(mapping, 1, 0)); defer { AudioRealtimeDestroy(state) }
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(!AudioRealtimeHasRendered(state)); #expect(!AudioRealtimeHasFault(state))
}
@Test func realtimeOutputPeakNeverExceedsRequestedGain() throws {
    let samples: [Float] = [0.25, -0.25, 1, -1, 1.2, -1.2, 2, 100, -100, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    let input = TestAudioBuffers(channels: [1], frames: samples.count), output = TestAudioBuffers(channels: [1], frames: samples.count)
    for i in samples.indices { input.samples[0][i] = samples[i] }
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    for gain: Float in [0, 0.05, 0.1, 0.25, 0.5, 0.75, 1] {
        let state = try #require(AudioRealtimeCreate(mapping, gain, 0)); defer { AudioRealtimeDestroy(state) }
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        for (sample, value) in zip(samples, output.values[0]) {
            #expect(abs(value) <= gain, "\(sample) at \(gain)")
            #expect(abs(value) <= abs(sample), "\(sample) at \(gain)")
        }
    }
    let state = try #require(AudioRealtimeCreate(mapping, 0.5, 0)); defer { AudioRealtimeDestroy(state) }
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values[0] == [0.125, -0.125, 0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, 0.5, -0.5])
}
@Test func realtimeRampsTowardSanitizedGainWhenTargetIsOversizedOrNonfinite() throws {
    let input = TestAudioBuffers(channels: [1], frames: 4, fill: 1), output = TestAudioBuffers(channels: [1], frames: 4)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let cases: [(Float, [Float])] = [
        (4, [0.625, 0.75, 0.875, 1]),
        (.infinity, [0.375, 0.25, 0.125, 0]),
        (.nan, [0.375, 0.25, 0.125, 0]),
        (-.infinity, [0.375, 0.25, 0.125, 0]),
        (-1, [0.375, 0.25, 0.125, 0])
    ]
    for (requested, expected) in cases {
        let state = try #require(AudioRealtimeCreate(mapping, 0.5, 4)); defer { AudioRealtimeDestroy(state) }
        AudioRealtimeSetGain(state, requested)
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        #expect(output.values[0] == expected, "\(requested)")
    }
}
@Test func realtimeLongRampIsMonotonicAndLandsExactlyOnTarget() throws {
    let input = TestAudioBuffers(channels: [1], frames: 960, fill: 1), output = TestAudioBuffers(channels: [1], frames: 960)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let cases: [(Float, Float)] = [(0, 1), (1, 0), (0.1, 0.7), (0.7, 0.1)]
    for (start, target) in cases {
        let state = try #require(AudioRealtimeCreate(mapping, start, 960)); defer { AudioRealtimeDestroy(state) }
        AudioRealtimeSetGain(state, target)
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        let ramp = output.values[0]
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { target > start ? $0 <= $1 : $0 >= $1 }, "\(start) to \(target)")
        #expect(ramp.last == target, "\(start) to \(target)")
    }
}
@Test func realtimeRampRoundingNeverCarriesPastTarget() throws {
    let input = TestAudioBuffers(channels: [1], frames: 960, fill: 1), output = TestAudioBuffers(channels: [1], frames: 960)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    // These steps round to a whole unit in the last place, so 960 of them travel too far.
    let near: Float = 0.5, far = near + 481 * near.ulp
    for (start, target) in [(near, far), (far, near)] {
        let state = try #require(AudioRealtimeCreate(mapping, start, 960)); defer { AudioRealtimeDestroy(state) }
        AudioRealtimeSetGain(state, target)
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        #expect(output.values[0].allSatisfy { (near...far).contains($0) }, "\(start) to \(target)")
        #expect(output.values[0].last == target, "\(start) to \(target)")
    }
}
@Test func realtimeCreateTreatsNonfiniteInitialGainAsSilence() throws {
    let input = TestAudioBuffers(channels: [1], frames: 4, fill: 1), output = TestAudioBuffers(channels: [1], frames: 4, fill: 1)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    for initial: Float in [.nan, .infinity, -.infinity] {
        let state = try #require(AudioRealtimeCreate(mapping, initial, 4)); defer { AudioRealtimeDestroy(state) }
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        #expect(output.values[0] == [0, 0, 0, 0], "\(initial)")
        AudioRealtimeSetGain(state, 0.5)
        #expect(AudioRealtimeProcess(state, input.list, output.list))
        #expect(output.values[0] == [0.125, 0.25, 0.375, 0.5], "\(initial)")
    }
}
@Test func realtimeIOProcWithoutContextClearsOutputAndReportsSuccess() {
    let input = TestAudioBuffers(channels: [2], frames: 2, fill: 1), output = TestAudioBuffers(channels: [2], frames: 2, fill: 1)
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioRealtimeIOProc(0, time, input.list, time, output.list, time, nil) == noErr)
    }
    #expect(output.values[0].allSatisfy { $0 == 0 })
}
@Test func realtimeConfigureStreamsRejectsInvalidArgumentsBeforeReachingTheHAL() {
    let proc: AudioDeviceIOProcID = AudioRealtimeIOProc
    let enabled = [UInt32](repeating: 1, count: 65)
    let cases: [(AudioDeviceIOProcID?, UInt32)] = [(nil, 1), (proc, 0), (proc, 65)]
    for (candidate, count) in cases {
        let status = AudioRealtimeConfigureStreams(kAudioObjectUnknown, candidate, kAudioObjectPropertyScopeOutput, count, enabled)
        #expect(status == kAudioHardwareIllegalOperationError, "\(count)")
    }
}
@Test func realtimeGainStateIsIndependentForEachApplication() throws {
    let input = TestAudioBuffers(channels: [1], frames: 2, fill: 0.8), outputA = TestAudioBuffers(channels: [1], frames: 2), outputB = TestAudioBuffers(channels: [1], frames: 2)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let a = try #require(AudioRealtimeCreate(mapping, 0.5, 0)), b = try #require(AudioRealtimeCreate(mapping, 0.25, 0))
    defer { AudioRealtimeDestroy(a); AudioRealtimeDestroy(b) }
    #expect(AudioRealtimeProcess(a, input.list, outputA.list)); #expect(AudioRealtimeProcess(b, input.list, outputB.list))
    #expect(outputA.values == [[0.4, 0.4]]); #expect(outputB.values == [[0.2, 0.2]])
    AudioRealtimeSetGain(a, 0)
    #expect(AudioRealtimeProcess(a, input.list, outputA.list)); #expect(AudioRealtimeProcess(b, input.list, outputB.list))
    #expect(outputA.values == [[0, 0]]); #expect(outputB.values == [[0.2, 0.2]])
}
@Test func pcmValidationRejectsUnsafeFormatsAndRateOrChannelMismatch() throws {
    let stereo = try AudioPCMLayout(pcm())
    for invalid in [pcm(channels: 3), pcm(rate: .nan), pcm(rate: 0)] {
        #expect(throws: AudioBackendError.self) { try AudioPCMLayout(invalid) }
    }
    var integer = pcm(); integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    #expect(throws: AudioBackendError.self) { try AudioPCMLayout(integer) }
    var bytes = pcm(); bytes.mBytesPerFrame = 4
    #expect(throws: AudioBackendError.self) { try AudioPCMLayout(bytes) }
    var endian = pcm(); endian.mFormatFlags |= kAudioFormatFlagIsBigEndian
    #expect(throws: AudioBackendError.self) { try AudioPCMLayout(endian) }
    #expect(throws: AudioBackendError.self) { try stereo.mapping(to: AudioPCMLayout(pcm(rate: 44_100))) }
    #expect(throws: AudioBackendError.self) { try stereo.mapping(to: AudioPCMLayout(pcm(channels: 1))) }
}

@Test func accessProbeRequiresFiniteLiveSignalAndNeverReplaysIt() throws {
    let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
    let input = TestAudioBuffers(channels: [2], frames: 2), output = TestAudioBuffers(channels: [2], frames: 2, fill: 1)
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(!AudioAccessProbeObservedSignal(state)); #expect(output.values[0].allSatisfy { $0 == 0 })
        input.samples[0][0] = .nan; input.samples[0][1] = .infinity
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(!AudioAccessProbeObservedSignal(state))
        input.samples[0][2] = 0.0001
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(AudioAccessProbeObservedSignal(state)); #expect(output.values[0].allSatisfy { $0 == 0 })
    }
}

@Test func accessProbeNotifiesOnceWhenSilenceBecomesFiniteSignal() throws {
    let descriptors = try AudioHAL.makeNonblockingPipe(purpose: "test")
    defer { close(descriptors.read); close(descriptors.write) }
    let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
    AudioAccessProbeSetSignalFileDescriptor(state, descriptors.write)
    let input = TestAudioBuffers(channels: [2], frames: 2), output = TestAudioBuffers(channels: [2], frames: 2, fill: 1)
    var byte: UInt8 = 0
    withUnsafePointer(to: AudioTimeStamp()) { time in
        for samples: [Float] in [[0, 0, 0, 0], [.nan, .infinity, -.infinity, -0.0]] {
            for index in samples.indices { input.samples[0][index] = samples[index] }
            #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
            #expect(!AudioAccessProbeObservedSignal(state))
            #expect(read(descriptors.read, &byte, 1) == -1)
            #expect(errno == EAGAIN)
        }
        input.samples[0][2] = 0.0001
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(AudioAccessProbeObservedSignal(state))
        #expect(read(descriptors.read, &byte, 1) == 1)
        #expect(byte == 1)
        for _ in 0..<10 {
            #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        }
        #expect(read(descriptors.read, &byte, 1) == -1)
        #expect(errno == EAGAIN)
        #expect(output.values[0].allSatisfy { $0 == 0 })
    }
}

@Test func accessProbeDoesNotRetryNotificationWhenNonblockingPipeIsFull() throws {
    let descriptors = try AudioHAL.makeNonblockingPipe(purpose: "test")
    defer { close(descriptors.read); close(descriptors.write) }
    var bytes = [UInt8](repeating: 0, count: 1024)
    while bytes.withUnsafeBytes({ write(descriptors.write, $0.baseAddress, $0.count) }) > 0 {}
    // A final one-byte fill also consumes any capacity smaller than the bulk write.
    var byte: UInt8 = 0
    while write(descriptors.write, &byte, 1) == 1 {}
    #expect(errno == EAGAIN)
    let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
    AudioAccessProbeSetSignalFileDescriptor(state, descriptors.write)
    let input = TestAudioBuffers(channels: [1], frames: 1, fill: 0.2), output = TestAudioBuffers(channels: [1], frames: 1)
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(AudioAccessProbeObservedSignal(state))
        while bytes.withUnsafeMutableBytes({ read(descriptors.read, $0.baseAddress, $0.count) }) > 0 {}
        #expect(errno == EAGAIN)
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(read(descriptors.read, &byte, 1) == -1)
        #expect(errno == EAGAIN)
    }
}

@Test func accessProbeRejectsMalformedInputBeforeObservingSignal() throws {
    let mutations: [(UnsafeMutablePointer<AudioBufferList>) -> Void] = [
        { $0.pointee.mNumberBuffers = 0 },
        { $0.pointee.mNumberBuffers = 65 },
        { $0.pointee.mNumberBuffers = UInt32.max },
        { $0.pointee.mBuffers.mNumberChannels = 0 },
        { $0.pointee.mBuffers.mNumberChannels = 2 },
        { $0.pointee.mBuffers.mNumberChannels = 3 },
        { $0.pointee.mBuffers.mDataByteSize = 3 },
        { $0.pointee.mBuffers.mDataByteSize = 1_048_580 },
        { $0.pointee.mBuffers.mDataByteSize = UInt32.max },
        { $0.pointee.mBuffers.mData = nil },
        { $0.pointee.mBuffers.mData = $0.pointee.mBuffers.mData!.advanced(by: 1) }
    ]
    for mutate in mutations {
        let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
        let input = TestAudioBuffers(channels: [1], frames: 1, fill: 0.2), output = TestAudioBuffers(channels: [1], frames: 1, fill: 1)
        mutate(input.list)
        withUnsafePointer(to: AudioTimeStamp()) { time in
            #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        }
        #expect(!AudioAccessProbeObservedSignal(state))
        #expect(output.values[0] == [0])
    }
    // Validate every buffer before inspecting a positive sample in the first one.
    let planar = TestAudioBuffers(channels: [1, 1], frames: 2, fill: 0.2), output = TestAudioBuffers(channels: [2], frames: 2)
    let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
    let buffers = UnsafeMutableAudioBufferListPointer(planar.list)
    buffers[1].mDataByteSize = 4
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioAccessProbeIOProc(0, time, planar.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
    }
    #expect(!AudioAccessProbeObservedSignal(state))
    buffers[1].mDataByteSize = 8
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioAccessProbeIOProc(0, time, planar.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
    }
    #expect(AudioAccessProbeObservedSignal(state))
}

@Test func accessProbeRejectsOversizedOutputMetadataWithoutObservingSignal() throws {
    let state = try #require(AudioAccessProbeCreate()); defer { AudioAccessProbeDestroy(state) }
    let input = TestAudioBuffers(channels: [1], frames: 1, fill: 0.2), output = TestAudioBuffers(channels: [1], frames: 1)
    withUnsafePointer(to: AudioTimeStamp()) { time in
        output.list.pointee.mNumberBuffers = 65
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(!AudioAccessProbeObservedSignal(state))
        output.list.pointee.mNumberBuffers = 1
        output.list.pointee.mBuffers.mDataByteSize = 1_048_580
        #expect(AudioAccessProbeIOProc(0, time, input.list, time, output.list, time, UnsafeMutableRawPointer(state)) == noErr)
        #expect(!AudioAccessProbeObservedSignal(state))
    }
}

@Test func realtimeMalformedBufferSendsOnlyOneNonblockingFailureWakeup() throws {
    let descriptors = try AudioHAL.makeNonblockingPipe(purpose: "test")
    defer { close(descriptors.read); close(descriptors.write) }
    let input = TestAudioBuffers(channels: [1], frames: 1), output = TestAudioBuffers(channels: [1], frames: 2)
    let mapping = try AudioPCMLayout(pcm(channels: 1)).mapping(to: AudioPCMLayout(pcm(channels: 1)))
    let state = try #require(AudioRealtimeCreate(mapping, 1, 0)); defer { AudioRealtimeDestroy(state) }
    AudioRealtimeSetFaultFileDescriptor(state, descriptors.write)
    #expect(!AudioRealtimeProcess(state, input.list, output.list))
    var byte: UInt8 = 0
    #expect(read(descriptors.read, &byte, 1) == 1); #expect(byte == 1)
    #expect(!AudioRealtimeProcess(state, input.list, output.list))
    #expect(read(descriptors.read, &byte, 1) == -1)
    #expect(errno == EAGAIN)
}
