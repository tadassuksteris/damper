#if DEBUG
import AudioRealtime
import CoreAudio
import Foundation

/// Opt-in integration check for the two generated fixtures. Never writes hardware settings.
@MainActor
package final class AudioIntegrationCheck {
    private let backend = CoreAudioBackend()
    private var snapshot = AudioSnapshot()
    private var failure: String?
    private let ids = ["io.github.tadassuksteris.damper.fixture.a", "io.github.tadassuksteris.damper.fixture.b"]
    private static let ratioTolerance = 0.05

    package init() {}

    package func run() async throws -> String {
        backend.onSnapshot = { [weak self] in self?.snapshot = $0 }
        backend.onFailure = { [weak self] in self?.failure = $0 }
        defer { backend.stop(); backend.drain(timeout: 2) }
        return try await verify()
    }

    private func verify() async throws -> String {
        try backend.startMonitoring()
        try await waitUntil("Both generated fixture apps must be playing.") {
            self.ids.allSatisfy { id in self.snapshot.clients.contains { $0.id == id && $0.isRunningOutput && $0.isControllable } }
        }
        let original = try AudioCheckSupport.hardwareState()
        try await backend.requestAccess()
        try backend.setProcessingEnabled(true)
        // Long enough for a person to answer the consent prompt on a first run.
        try await waitUntil("Live audio access was not verified.", seconds: 60) { self.snapshot.accessState == .verified }
        // Each fixture is measured on its own. B plays louder than A, so an adjustment that reaches
        // the wrong app changes the total by a different amount and fails its step.
        let objects = ids.map { id in snapshot.clients.first { $0.id == id }?.processObjectIDs ?? [] }
        guard objects.allSatisfy({ !$0.isEmpty }) else { throw AudioBackendError.unsupported("A fixture app stopped before it could be measured.") }
        let originalA = try await measure(processes: objects[0]), originalB = try await measure(processes: objects[1])
        guard originalA.rms > 0.00001, originalB.rms > 0.00001 else { throw AudioBackendError.unsupported("An original fixture is silent.") }
        guard abs(originalB.rms / originalA.rms - 2) < 0.2 else {
            throw AudioBackendError.unsupported("Fixture B must play at twice A's level (measured \(originalB.rms / originalA.rms)x). Rebuild them with scripts/build-audio-fixtures.sh.")
        }
        let powerA = pow(originalA.rms, 2), powerB = pow(originalB.rms, 2)
        let originalRMS = (powerA + powerB).squareRoot()

        let half = AppAdjustment(volume: 0.5), lowered = AppAdjustment(volume: 0.4)
        let halfMuted = AppAdjustment(volume: 0.5, muted: true), loweredMuted = AppAdjustment(volume: 0.4, muted: true)
        try apply(half, half)
        try await waitUntil("The fixture pipelines did not start.") { self.bothApplied }
        let baseline = try await measureApplied("Both at 50%")
        var rows = [row("Both at 50%", baseline, baseline: originalRMS, expected: Double(half.effectiveGain))]
        try requirePassed(rows)

        let steps: [(String, AppAdjustment, AppAdjustment)] = [
            ("A muted; B at 50%", halfMuted, half),
            ("A muted; B at 40%", halfMuted, lowered),
            ("A at 50%; B at 40%", half, lowered),
            ("Both muted", halfMuted, loweredMuted)
        ]
        for (name, a, b) in steps {
            try apply(a, b)
            let value = try await measureApplied(name)
            rows.append(row(name, value, baseline: baseline.rms,
                            expected: Self.expectedRatio(a, b, baseline: half, powerA: powerA, powerB: powerB)))
            try requirePassed(rows)
        }

        try backend.setProcessingEnabled(false)
        backend.drain(timeout: 2)
        try await waitUntil("Pausing left a private Damper device behind.") { (try? AudioCheckSupport.privateDevices().isEmpty) == true }
        guard try AudioCheckSupport.hardwareState() == original else {
            throw AudioBackendError.unsupported("Hardware settings changed during the check; no restoration was attempted.")
        }
        let report: [String: Any] = [
            "mode": "generated fixtures; post-processing RMS only; no audio saved",
            "hardware": original.filter { $0.key != "uid" }, "checks": rows,
            "originalFixtureRMS": ["a": originalA.rms, "b": originalB.rms],
            "scope": "Measures Damper's own output before hardware. Does not establish audible playback, latency, or first-sound interception."
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    private var bothApplied: Bool {
        ids.allSatisfy { id in snapshot.clients.contains { $0.id == id && $0.isAdjustmentApplied } }
    }

    private func apply(_ a: AppAdjustment, _ b: AppAdjustment) throws {
        backend.setAdjustment(a, for: ids[0])
        backend.setAdjustment(b, for: ids[1])
    }

    /// Waits out the gain ramp, then measures. A pipeline that failed meanwhile plays the original
    /// audio, so its reading would not show the applied level.
    private func measureApplied(_ step: String) async throws -> Measurement {
        try await Task.sleep(for: .milliseconds(150))
        let value = try await measure()
        guard bothApplied else {
            throw AudioBackendError.unsupported("A fixture pipeline stopped during \(step), so its reading does not show the applied level.")
        }
        return value
    }

    private func requirePassed(_ rows: [[String: Any]]) throws {
        guard rows.last?["passed"] as? Bool == true else {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            throw AudioBackendError.unsupported("Live gain check failed: \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func waitUntil(_ message: String, seconds: Int = 4, predicate: () -> Bool) async throws {
        for _ in 0..<(seconds * 20) {
            if let error = AudioCheckSupport.blockingError(accessState: snapshot.accessState, failure: failure) { throw error }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let detail = snapshot.clients.filter { ids.contains($0.id) }.map { "\($0.name): \($0.unavailableReason ?? "no failure reported")" }.joined(separator: "; ")
        throw AudioBackendError.unsupported(message + " " + detail)
    }

    private func row(_ name: String, _ value: Measurement, baseline: Double, expected: Double) -> [String: Any] {
        let ratio = value.rms / baseline
        return ["step": name, "rms": value.rms, "sampleCount": value.samples, "ratio": ratio,
                "expectedRatio": expected, "passed": Self.matches(ratio, expected: expected)]
    }

    /// The fixtures are independent tones, so their measured powers add.
    static func expectedRatio(_ a: AppAdjustment, _ b: AppAdjustment, baseline: AppAdjustment,
                              powerA: Double, powerB: Double) -> Double {
        func gain(_ adjustment: AppAdjustment) -> Double { pow(Double(adjustment.effectiveGain), 2) }
        return ((gain(a) * powerA + gain(b) * powerB) / (gain(baseline) * (powerA + powerB))).squareRoot()
    }

    /// Relative, because the gain curve puts the expected ratios at very different sizes.
    static func matches(_ ratio: Double, expected: Double) -> Bool {
        expected == 0 ? ratio < 0.001 : abs(ratio / expected - 1) < ratioTolerance
    }

    private func measure(processes: [UInt32]? = nil) async throws -> Measurement {
        try await Task.detached(priority: .userInitiated) { try Self.readOutput(processes: processes) }.value
    }

    private struct Measurement: Sendable { let rms: Double; let samples: UInt64 }

    nonisolated private static func readOutput(processes selected: [UInt32]?) throws -> Measurement {
        let processes = try selected ?? AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyProcessObjectList).filter {
            (try? AudioHAL.uint($0, kAudioProcessPropertyPID)) == UInt32(getpid())
        }
        guard !processes.isEmpty, let state = AudioMeasurementCreate() else {
            throw AudioBackendError.unsupported("Cannot find the mixer's own output process or allocate its diagnostic state.")
        }
        var tap: UInt32 = 0, aggregate: UInt32 = 0
        var ioProc: AudioDeviceIOProcID?
        var detached = true
        func detach() {
            // A later call has nothing left to remove and must keep an earlier false result.
            guard ioProc != nil || aggregate != 0 || tap != 0 else { return }
            detached = AudioHAL.destroyTapReader(tap: tap, aggregate: aggregate, ioProc: ioProc)
            ioProc = nil; aggregate = 0; tap = 0
        }
        defer { detach(); if detached { AudioMeasurementDestroy(state) } }
        let labels = TapOnlyReaderLabels(
            tapName: "Damper generated-audio check", createTap: "Create diagnostic tap",
            deviceName: "Damper private diagnostic", deviceUIDKind: "check", createDevice: "Create diagnostic input",
            containsHardware: "The diagnostic input is not an isolated Float32 tap.",
            invalidInput: "The diagnostic input is not an isolated Float32 tap.")
        try AudioHAL.createTapOnlyReader(processes: processes, labels: labels, tap: &tap, aggregate: &aggregate)
        try AudioHAL.check(AudioDeviceCreateIOProcID(aggregate, AudioMeasurementIOProc, UnsafeMutableRawPointer(state), &ioProc), "Create measurement callback")
        guard let ioProc else { throw AudioBackendError.unsupported("Missing measurement callback.") }
        try AudioHAL.check(AudioDeviceStart(aggregate, ioProc), "Start diagnostic input")
        Thread.sleep(forTimeInterval: 0.4)
        detach()
        guard detached, AudioMeasurementValid(state), AudioMeasurementSampleCount(state) > 0 else {
            throw AudioBackendError.unsupported("The diagnostic callback did not provide valid samples or detach safely.")
        }
        return Measurement(rms: AudioMeasurementRMS(state), samples: AudioMeasurementSampleCount(state))
    }
}
#endif
