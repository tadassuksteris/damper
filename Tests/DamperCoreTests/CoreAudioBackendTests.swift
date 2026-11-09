import AudioRealtime
import CoreAudio
import Foundation
import Testing
@testable import DamperCore

@Test @MainActor func backendRequiresAccessRequestBeforeEnablingAndPublishesOnAdjustment() throws {
    let backend = CoreAudioBackend()
    var snapshots: [AudioSnapshot] = []
    backend.onSnapshot = { snapshots.append($0) }
    backend.setAdjustment(AppAdjustment(volume: 0.5), for: "org.example.notRunning")
    backend.setAdjustment(AppAdjustment(muted: true), for: "org.example.notRunning")
    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy { $0.accessState == .notRequested })
    #expect(throws: AudioBackendError.self) { try backend.setProcessingEnabled(true) }
    try backend.setProcessingEnabled(false)
    backend.removeAdjustment(for: "org.example.notRunning")
    backend.stop(); backend.stop()
}

@Test func aPermissionStatusIsOnlyDeniedAccessInsideTheAccessSession() {
    #expect(throws: AudioBackendError.operationFailed("Probe", kAudioDevicePermissionsError)) {
        try AudioHAL.check(kAudioDevicePermissionsError, "Probe")
    }
    #expect(throws: AudioBackendError.operationFailed("Probe", kAudioHardwareNotReadyError)) {
        try AudioHAL.check(kAudioHardwareNotReadyError, "Probe")
    }
    #expect(CoreAudioAccessSession.accessError(AudioBackendError.operationFailed("Probe", kAudioDevicePermissionsError)) == .permissionDenied)
    #expect(CoreAudioAccessSession.accessError(AudioBackendError.operationFailed("Probe", kAudioHardwareNotReadyError))
        == .operationFailed("Probe", kAudioHardwareNotReadyError))
    #expect(CoreAudioAccessSession.accessError(AudioBackendError.unsupported("No reader.")) == .unsupported("No reader."))
}

private struct RefreshOutage: LocalizedError {
    var errorDescription: String? { "Outage." }
}

@Test @MainActor func aRouteFailureIsNotReportedWhileARefreshRetryIsPending() throws {
    let backend = CoreAudioBackend()
    let noOutput = AudioBackendError.unsupported("No system output is available.").localizedDescription
    var reasons: [String?] = [], failures: [String] = []
    backend.onSnapshot = { reasons.append($0.outputUnsupportedReason) }
    backend.onFailure = { failures.append($0) }

    backend.refreshFailed(RefreshOutage(), final: false)
    #expect(reasons == [nil])
    backend.setAdjustment(AppAdjustment(volume: 0.5), for: "org.example.notRunning")
    #expect(reasons == [nil, nil])
    #expect(failures.isEmpty)

    backend.refreshFailed(RefreshOutage(), final: true)
    #expect(reasons.last == noOutput)
    #expect(failures == ["Outage."])

    // A real reason from before the outage stays while the next retry is pending.
    backend.refreshFailed(RefreshOutage(), final: false)
    #expect(reasons.last == noOutput)

    backend.stop()
}

@Test @MainActor func stoppingEndsAPendingRefreshRetry() throws {
    let backend = CoreAudioBackend()
    var reasons: [String?] = []
    backend.onSnapshot = { reasons.append($0.outputUnsupportedReason) }
    backend.refreshFailed(RefreshOutage(), final: false)
    backend.stop()
    backend.setAdjustment(AppAdjustment(volume: 0.5), for: "org.example.notRunning")
    #expect(reasons.last == AudioBackendError.unsupported("No system output is available.").localizedDescription)
    backend.stop()
}

/// The outputs don't exist, so each start ends at its first read and creates nothing.
@Test func aBlockedPipelineHoldsUpOnlyItsOwnApp() throws {
    let request = AudioPipelineRequest(processes: [], bundleIDs: [], output: kAudioObjectUnknown, outputUID: "", outputFormat: try AudioPCMLayout(pcm()))
    let work = DispatchGroup()
    let gate = DispatchSemaphore(value: 0), blockedFinished = DispatchSemaphore(value: 0), otherFinished = DispatchSemaphore(value: 0)
    let blocked = CoreAudioPipeline(request: request, work: work)
    let other = CoreAudioPipeline(request: request, work: work)
    blocked.queue.async { gate.wait() }
    blocked.start(gain: 1) { _ in blockedFinished.signal() }
    other.start(gain: 1) { _ in otherFinished.signal() }

    #expect(otherFinished.wait(timeout: .now() + 5) == .success)
    other.stop()
    #expect(blockedFinished.wait(timeout: .now() + 0.05) == .timedOut)
    #expect(!blocked.hasRendered)
    #expect(work.wait(timeout: .now() + 0.05) == .timedOut)

    gate.signal()
    #expect(blockedFinished.wait(timeout: .now() + 5) == .success)
    blocked.stop()
    #expect(work.wait(timeout: .now() + 5) == .success)
}

/// Quit waits on the group, so a retired pipeline's teardown must count until it has run.
@Test func aStoppedPipelinesTeardownCountsUntilItRuns() throws {
    let request = AudioPipelineRequest(processes: [], bundleIDs: [], output: kAudioObjectUnknown, outputUID: "", outputFormat: try AudioPCMLayout(pcm()))
    let work = DispatchGroup(), gate = DispatchSemaphore(value: 0)
    let pipeline = CoreAudioPipeline(request: request, work: work)
    pipeline.queue.async { gate.wait() }
    pipeline.stop()
    #expect(work.wait(timeout: .now() + 0.05) == .timedOut)
    gate.signal()
    #expect(work.wait(timeout: .now() + 5) == .success)
}

@Test func theRealtimeHandleSetsGainAndReadsRenderingWithoutThePipelineQueue() throws {
    let layout = try AudioPCMLayout(pcm())
    let state = try #require(AudioRealtimeCreate(try layout.mapping(to: layout), 1, 0)); defer { AudioRealtimeDestroy(state) }
    let input = TestAudioBuffers(channels: [2], frames: 2, fill: 1), output = TestAudioBuffers(channels: [2], frames: 2)
    let handle = RealtimeHandle()

    // A gain set before the state exists is applied when it's attached.
    handle.setGain(0.25)
    #expect(!handle.hasRendered)
    handle.attach(state)
    #expect(!handle.hasRendered)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(handle.hasRendered && output.values[0].allSatisfy { $0 == 0.25 })

    handle.setGain(0.5)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values[0].allSatisfy { $0 == 0.5 })

    // Once detached, the state is out of reach before teardown frees it.
    handle.attach(nil)
    handle.setGain(0)
    #expect(!handle.hasRendered)
    #expect(AudioRealtimeProcess(state, input.list, output.list))
    #expect(output.values[0].allSatisfy { $0 == 0.5 })
}

@Test @MainActor func everyExhaustedRefreshFailureIsReportedSoARetryCannotStallSilently() {
    let backend = CoreAudioBackend()
    var failures = 0
    backend.onFailure = { _ in failures += 1 }
    backend.refreshFailed(RefreshOutage(), final: true)
    backend.refreshFailed(RefreshOutage(), final: true)
    #expect(failures == 2)
}
