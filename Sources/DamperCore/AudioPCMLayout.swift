import AudioRealtime
import CoreAudio

struct AudioPCMLayout: Equatable, Sendable {
    let sampleRate: Double
    let channels: UInt32
    let planar: Bool

    init(_ format: AudioStreamBasicDescription) throws {
        let flags = format.mFormatFlags
        let allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        let stride: UInt32 = planar ? 1 : format.mChannelsPerFrame
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsFloat != 0, flags & kAudioFormatFlagIsPacked != 0,
              flags & ~allowed == 0, format.mBitsPerChannel == 32,
              (1...2).contains(format.mChannelsPerFrame), format.mFramesPerPacket == 1,
              format.mBytesPerFrame == stride * 4, format.mBytesPerPacket == stride * 4,
              (8_000...192_000).contains(format.mSampleRate) else {
            throw AudioBackendError.unsupported("This output’s audio format isn’t supported. It needs mono or stereo 32-bit float at 8–192 kHz.")
        }
        sampleRate = format.mSampleRate; channels = format.mChannelsPerFrame; self.planar = planar
    }
    var buffers: [UInt32] { planar ? Array(repeating: 1, count: Int(channels)) : [channels] }
    func mapping(to output: AudioPCMLayout) throws -> AudioRealtimeLayout {
        guard sampleRate == output.sampleRate, channels == output.channels else {
            throw AudioBackendError.unsupported("This app’s audio and this output use different formats, and the app doesn’t convert between them.")
        }
        var result = AudioRealtimeLayout()
        result.channels = channels
        result.inputStride = planar ? 1 : channels; result.outputStride = output.planar ? 1 : channels
        result.inputBufferCount = UInt32(buffers.count); result.outputBufferCount = UInt32(output.buffers.count)
        result.inputBuffer = (0, planar && channels == 2 ? 1 : 0)
        result.inputChannel = (0, planar ? 0 : 1)
        result.outputBuffer = (0, output.planar && channels == 2 ? 1 : 0)
        result.outputChannel = (0, output.planar ? 0 : 1)
        return result
    }
}
