import Foundation

/// The backend's pure decisions, separated from its HAL and task state so tests reach them directly.
enum CoreAudioBackendLogic {
    static func pipelinesAllowed(monitoring: Bool, enabled: Bool, sleeping: Bool, accessState: AudioAccessState) -> Bool {
        monitoring && enabled && !sleeping && accessState == .verified
    }

    /// Removing a live tap from a playing app is audible, so an app returned to its full level
    /// keeps its pipeline, at unity gain, until it stops playing. Ignoring an app is the exception,
    /// because ignore means staying out of its audio.
    static func needsPipeline(_ adjustment: AppAdjustment, hasPipeline: Bool) -> Bool {
        adjustment.needsProcessing || (hasPipeline && !adjustment.ignored)
    }

    /// A failure is cleared when its app starts output IO again, which only the user or the app
    /// can cause. An app that was not listed before counts as starting.
    static func idsThatStartedRunning(previous: [DiscoveredClient], current: [DiscoveredClient]) -> [String] {
        let wasRunning = Set(previous.filter(\.running).map(\.id))
        return current.filter { $0.running && !wasRunning.contains($0.id) }.map(\.id)
    }

    /// The running processes an access reader may tap. An ignored app stays on its original path.
    static func accessSources(clients: [DiscoveredClient], desired: [String: AppAdjustment]) -> [UInt32] {
        Array(Set(clients.filter { $0.running && desired[$0.id]?.ignored != true }.flatMap(\.objects))).sorted()
    }

    /// The owner of a device's hog mode when it is another process. Our own hog, which the HAL
    /// can take for a non-mixable device when an IOProc starts, does not count.
    static func externalHogOwner(_ owner: pid_t?) -> pid_t? {
        guard let owner, owner != -1, owner != getpid() else { return nil }
        return owner
    }

    /// The current default stays listed even if it reports it cannot be one, because dropping it
    /// would remove the output controls for the device macOS is using. An unreadable property
    /// stays listed too.
    static func isOfferedAsOutput(_ device: UInt32, selected: UInt32?, canBeDefault: UInt32?) -> Bool {
        device == selected || canBeDefault != 0
    }

    /// Gaps between render checks for a new pipeline, reaching about 0.2, 1, 3 and 9 seconds.
    static let renderCheckIntervals: [Duration] = [.milliseconds(200), .milliseconds(800), .seconds(2), .seconds(6)]
    /// After the last check, a pipeline that still has not rendered is reported as failed.
    static let renderDeadlineAfterLastCheck: Duration = .seconds(1)
    static let noRenderFailure = "Audio processing did not start. Original playback has been restored."

    struct AccessFlags: Equatable {
        var enabled: Bool
        var requestedAccess: Bool
        var accessState: AudioAccessState
    }

    /// The state after an access session reports, and any failure to surface. A session
    /// that was already stopping leaves everything as it was.
    static func applying(_ result: AudioAccessSessionResult, stopping: Bool, sleeping: Bool,
                         to state: AccessFlags) -> (state: AccessFlags, failure: String?) {
        guard !stopping else { return (state, nil) }
        var next = state
        var failure: String?
        switch result {
        case .observedSignal:
            if state.requestedAccess && state.enabled && !sleeping { next.accessState = .verified }
        case .cancelled: break
        case let .failed(error):
            next.enabled = false
            next.accessState = error == .permissionDenied ? .denied : .notRequested
            if error == .permissionDenied { next.requestedAccess = false }
            else { failure = error.localizedDescription }
        }
        return (next, failure)
    }

    static func clientSnapshot(client: DiscoveredClient, adjustment: AppAdjustment, enabled: Bool, sleeping: Bool,
                               accessState: AudioAccessState, routeRejection: String?, failure: String?,
                               hasPipeline: Bool, started: Bool, rendered: Bool) -> AudioClientSnapshot {
        var reason = client.reason ?? routeRejection
        var controllable = reason == nil
        var applied = !adjustment.needsProcessing
        var canRetry = false
        // A client or route rejection is the true reason, and waiting cannot resolve it.
        if adjustment.needsProcessing, controllable {
            if !enabled { reason = "App levels are paused." }
            else if sleeping { reason = "Audio processing is suspended during sleep." }
            else if accessState != .verified { reason = "Waiting for audio access. Your saved level is kept." }
            else if !client.running { reason = "Waiting for output IO. Your saved level is kept." }
            else if let failure { reason = failure; controllable = false; canRetry = true }
            else if started && rendered { applied = true }
            else if hasPipeline { reason = "Waiting for the application audio callback. Access and playback are not yet verified." }
            else { reason = "Reconnecting. Your saved level is kept." }
        }
        return AudioClientSnapshot(id: client.id, name: client.name, bundleIdentifier: client.bundleID,
            applicationURL: client.url, processObjectIDs: client.objects,
            isRunningOutput: client.running, isControllable: controllable,
            unavailableReason: reason, isAdjustmentApplied: applied,
            isAdjustmentPending: controllable && enabled && !sleeping && client.running && !applied &&
                (hasPipeline || accessState == .waitingForAudio),
            canRetry: canRetry, hasStableIdentity: client.bundleID != nil)
    }
}
