import AppKit
import AVFAudio
import Foundation

/// A quiet, finite signal for opt-in local integration checks. No capture or hardware changes.
@main
enum AudioFixture {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let isB = Bundle.main.bundleIdentifier?.hasSuffix(".b") == true
        let frequency = isB ? 660.0 : 440.0
        // B plays at twice A's level, so the check can tell which app an adjustment reached.
        let amplitude = isB ? 0.005 : 0.0025
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / format.sampleRate) * amplitude)
            for channel in 0..<Int(format.channelCount) { buffer.floatChannelData![channel][frame] = value }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        try engine.start()
        player.play()
        RunLoop.current.run(until: Date().addingTimeInterval(180))
        player.stop(); engine.stop()
    }
}
