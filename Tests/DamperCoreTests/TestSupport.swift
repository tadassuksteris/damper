import CoreAudio
import Foundation
@testable import DamperCore

/// Owns planar or interleaved PCM buffers in memory, without opening any audio device.
final class TestAudioBuffers {
    let list: UnsafeMutablePointer<AudioBufferList>
    let samples: [UnsafeMutablePointer<Float>]
    private let memory: UnsafeMutableRawPointer
    private let channels: [UInt32]
    private let frames: Int

    init(channels: [UInt32], frames: Int, fill: Float = 0) {
        self.channels = channels; self.frames = frames
        let bytes = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + channels.count * MemoryLayout<AudioBuffer>.stride
        memory = .allocate(byteCount: max(bytes, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(channels.count)
        samples = channels.map { count in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames * Int(count)))
            pointer.initialize(repeating: fill, count: max(1, frames * Int(count)))
            return pointer
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for index in channels.indices {
            buffers[index] = AudioBuffer(mNumberChannels: channels[index], mDataByteSize: UInt32(frames * Int(channels[index]) * MemoryLayout<Float>.size),
                                         mData: samples[index])
        }
    }

    deinit {
        for pointer in samples { pointer.deallocate() }
        memory.deallocate()
    }

    var values: [[Float]] {
        channels.indices.map { Array(UnsafeBufferPointer(start: samples[$0], count: frames * Int(channels[$0]))) }
    }

    /// The kernel clears what the list declares, so metadata changes also change what must be zero.
    var declaredAreZero: Bool {
        zip(UnsafeMutableAudioBufferListPointer(list), samples).allSatisfy { buffer, pointer in
            buffer.mData == nil || UnsafeBufferPointer(start: pointer, count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size).allSatisfy { $0 == 0 }
        }
    }
}

/// Preferences that leave nothing on disk. Passing one instance to a second store models a relaunch.
final class InMemoryPreferences: PreferenceStorage {
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
}

func pcm(channels: UInt32 = 2, rate: Double = 48_000, planar: Bool = false) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: 4 * (planar ? 1 : channels), mFramesPerPacket: 1,
        mBytesPerFrame: 4 * (planar ? 1 : channels), mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}
