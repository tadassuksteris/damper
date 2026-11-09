import AudioRealtime
import CoreAudio
import Foundation
import Testing

@Test func measurementAccumulatesStereoEnergyAcrossCallbacks() throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    let input = TestAudioBuffers(channels: [2], frames: 2)
    input.samples[0][0] = 1
    input.samples[0][1] = -1
    AudioMeasurementProcess(state, input.list)
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 4)
    #expect(abs(AudioMeasurementRMS(state) - sqrt(0.5)) < 1e-12)

    let silence = TestAudioBuffers(channels: [2], frames: 2)
    AudioMeasurementProcess(state, silence.list)
    #expect(AudioMeasurementSampleCount(state) == 8)
    #expect(AudioMeasurementRMS(state) == 0.5)
}

@Test func measurementIncludesBothPlanarChannels() throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    let input = TestAudioBuffers(channels: [1, 1], frames: 2)
    for index in 0..<2 {
        input.samples[0][index] = 0.3
        input.samples[1][index] = -0.4
    }
    AudioMeasurementProcess(state, input.list)
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 4)
    #expect(abs(AudioMeasurementRMS(state) - sqrt(0.125)) < 1e-7)
}

@Test func measurementDistinguishesEmptyAndSilentInputBySampleCount() throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 0)
    #expect(AudioMeasurementRMS(state) == 0)

    let empty = TestAudioBuffers(channels: [1], frames: 0)
    empty.list.pointee.mBuffers.mData = nil
    AudioMeasurementProcess(state, empty.list)
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 0)
    let silence = TestAudioBuffers(channels: [1], frames: 64)
    AudioMeasurementProcess(state, silence.list)
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 64)
    #expect(AudioMeasurementRMS(state) == 0)
}

@Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
func measurementPermanentlyRejectsNonfiniteSamples(value: Float) throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    let input = TestAudioBuffers(channels: [1], frames: 2, fill: 0.5)
    AudioMeasurementProcess(state, input.list)
    input.samples[0][1] = value
    AudioMeasurementProcess(state, input.list)
    #expect(!AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 0)
    #expect(AudioMeasurementRMS(state) == 0)
    input.samples[0][1] = 0.5
    AudioMeasurementProcess(state, input.list)
    #expect(!AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 0)
}

@Test func measurementRejectsMalformedOrOversizedLayoutsBeforeReadingPCM() throws {
    for malformedCase in 0..<8 {
        let state = try #require(AudioMeasurementCreate())
        defer { AudioMeasurementDestroy(state) }
        let input = TestAudioBuffers(channels: [1, 1], frames: 2, fill: 0.5)
        let buffers = UnsafeMutableAudioBufferListPointer(input.list)
        switch malformedCase {
        case 0: input.list.pointee.mNumberBuffers = 0
        case 1: input.list.pointee.mNumberBuffers = 3
        case 2: buffers[0].mNumberChannels = 2
        case 3: buffers[0].mDataByteSize = 3
        case 4: buffers[1].mDataByteSize = 4
        case 5: buffers[0].mData = nil
        case 6: buffers[0].mDataByteSize = 1024 * 1024 + 4
        default: buffers[0].mData = UnsafeMutableRawPointer(input.samples[0]).advanced(by: 1)
        }
        AudioMeasurementProcess(state, input.list)
        #expect(!AudioMeasurementValid(state))
        #expect(AudioMeasurementSampleCount(state) == 0)
        #expect(AudioMeasurementRMS(state) == 0)
    }
}

@Test func measurementCallbackDiscardsOutputAndOnlyMeasuresInput() throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    let input = TestAudioBuffers(channels: [2], frames: 3, fill: -0.25)
    let output = TestAudioBuffers(channels: [1, 1], frames: 3, fill: 1)
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioMeasurementIOProc(0, time, input.list, time, output.list, time,
            UnsafeMutableRawPointer(state)) == noErr)
    }
    #expect(output.values == [[0, 0, 0], [0, 0, 0]])
    #expect(AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 6)
    #expect(AudioMeasurementRMS(state) == 0.25)
}

@Test func measurementRejectsMalformedOutputWhileClearingOtherOutputBuffers() throws {
    let state = try #require(AudioMeasurementCreate())
    defer { AudioMeasurementDestroy(state) }
    let input = TestAudioBuffers(channels: [1], frames: 2, fill: 0.5)
    let output = TestAudioBuffers(channels: [1, 1], frames: 2, fill: 1)
    UnsafeMutableAudioBufferListPointer(output.list)[0].mDataByteSize = 1024 * 1024 + 4
    withUnsafePointer(to: AudioTimeStamp()) { time in
        #expect(AudioMeasurementIOProc(0, time, input.list, time, output.list, time,
            UnsafeMutableRawPointer(state)) == noErr)
    }
    #expect(output.values[1] == [0, 0])
    #expect(!AudioMeasurementValid(state))
    #expect(AudioMeasurementSampleCount(state) == 0)
}

@Test func measurementAbsentContextHasNoResult() {
    AudioMeasurementProcess(nil, nil)
    AudioMeasurementDestroy(nil)
    #expect(!AudioMeasurementValid(nil))
    #expect(AudioMeasurementRMS(nil) == 0)
    #expect(AudioMeasurementSampleCount(nil) == 0)
}
