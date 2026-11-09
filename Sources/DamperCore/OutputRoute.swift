import CoreAudio

/// One output device's route properties, read on demand. A rejected route stops at the
/// failed check, so properties after it are never read.
protocol OutputRouteAccess {
    func objectClass() throws -> AudioClassID
    func streams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID]
    func streamFormat(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription
    func nominalRate() throws -> Float64
    func preferredStereo() throws -> [UInt32]
    func startingChannel(_ stream: AudioObjectID) throws -> UInt32
    func channels(scope: AudioObjectPropertyScope) throws -> [UInt32]
    /// Nil when the property cannot be read, which counts as free.
    func hogModeOwner() -> pid_t?
}

enum OutputRoute {
    /// A device that passed every check independent of any client.
    struct Validated {
        let output: AudioOutputSnapshot
        let format: AudioPCMLayout
    }

    static func validate(output: AudioOutputSnapshot?) throws -> Validated {
        try validate(output: output) { LiveOutputRouteAccess(device: $0) }
    }

    static func validate(output: AudioOutputSnapshot?, access: (AudioObjectID) -> any OutputRouteAccess) throws -> Validated {
        guard let output else { throw AudioBackendError.unsupported("No system output is available.") }
        return Validated(output: output, format: try validatedPlaybackFormat(access: access(output.id)))
    }

    /// The client's own checks, which read no device. A rejected route outranks them, so its
    /// reason is the same for every client without a client reason of its own.
    static func request(client: DiscoveredClient, route: Result<Validated, any Error>) throws -> AudioPipelineRequest {
        if let reason = client.reason { throw AudioBackendError.unsupported(reason) }
        let route = try route.get()
        guard !client.running || client.devices == [route.output.id] else {
            throw AudioBackendError.unsupported("Plays to another output. Can’t adjust it here.")
        }
        return AudioPipelineRequest(processes: client.objects, bundleIDs: client.bundleIDs.sorted(), output: route.output.id,
                                    outputUID: route.output.uid, outputFormat: route.format)
    }

    /// The device-level gate, without the checks that depend on a particular client.
    static func validatedPlaybackFormat(access: any OutputRouteAccess) throws -> AudioPCMLayout {
        guard try access.objectClass() != kAudioAggregateDeviceClassID else {
            throw AudioBackendError.unsupported("Aggregate and multi-output devices aren’t supported.")
        }
        guard CoreAudioBackendLogic.externalHogOwner(access.hogModeOwner()) == nil else {
            throw AudioBackendError.unsupported("Another app has exclusive use of this output.")
        }
        return try playbackFormat(access)
    }

    private static func playbackFormat(_ access: any OutputRouteAccess) throws -> AudioPCMLayout {
        let streams = try access.streams(scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else { throw AudioBackendError.unsupported("This output has more than one stream, which isn’t supported.") }
        let format = try AudioPCMLayout(access.streamFormat(streams[0]))
        guard try access.nominalRate() == format.sampleRate else {
            throw AudioBackendError.unsupported("This output’s sample rate doesn’t match its stream.")
        }
        if format.channels == 2, try access.preferredStereo() != [1, 2] {
            throw AudioBackendError.unsupported("This output’s stereo channel order isn’t supported.")
        }
        guard try access.channels(scope: kAudioObjectPropertyScopeInput).allSatisfy({ $0 == 0 }) else {
            throw AudioBackendError.unsupported("This output also has a microphone, which isn’t supported.")
        }
        guard try access.startingChannel(streams[0]) == 1,
              try access.streams(scope: kAudioObjectPropertyScopeInput).isEmpty else {
            throw AudioBackendError.unsupported("This output has input streams or a channel layout that isn’t supported.")
        }
        guard try access.channels(scope: kAudioObjectPropertyScopeOutput) == format.buffers else {
            throw AudioBackendError.unsupported("This output’s channel layout doesn’t match its stream.")
        }
        return format
    }
}

extension AudioHAL {
    static func validatedPlaybackFormat(device: AudioObjectID) throws -> AudioPCMLayout {
        try OutputRoute.validatedPlaybackFormat(access: LiveOutputRouteAccess(device: device))
    }
    static func hogModeOwner(device: AudioObjectID) -> pid_t? {
        try? scalar(device, kAudioDevicePropertyHogMode, initial: pid_t(-1))
    }
}

private struct LiveOutputRouteAccess: OutputRouteAccess {
    let device: AudioObjectID

    func objectClass() throws -> AudioClassID { try AudioHAL.uint(device, kAudioObjectPropertyClass) }
    func streams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        try AudioHAL.objects(device, kAudioDevicePropertyStreams, scope: scope)
    }
    func streamFormat(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription { try AudioHAL.format(stream) }
    func nominalRate() throws -> Float64 {
        try AudioHAL.scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }
    func preferredStereo() throws -> [UInt32] {
        try AudioHAL.objects(device, kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
    }
    func startingChannel(_ stream: AudioObjectID) throws -> UInt32 {
        try AudioHAL.uint(stream, kAudioStreamPropertyStartingChannel)
    }
    func channels(scope: AudioObjectPropertyScope) throws -> [UInt32] {
        try AudioHAL.channels(device, scope: scope)
    }
    func hogModeOwner() -> pid_t? { AudioHAL.hogModeOwner(device: device) }
}
