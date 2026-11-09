import Foundation

enum AudioBackendError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case operationFailed(String, Int32)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "System audio access is off. Turn on Damper in System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only."
        case let .operationFailed(operation, status): "\(operation) failed (\(Self.statusText(status)))."
        case let .unsupported(reason): reason
        }
    }

    /// HAL statuses are usually four printable characters, such as 'nrdy'.
    private static func statusText(_ status: Int32) -> String {
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(status) }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

public struct AppAdjustment: Codable, Equatable, Sendable {
    /// Slider position, which is what is saved and shown. `effectiveGain` turns it into amplitude.
    public var volume: Double { didSet { volume = Self.clamped(volume) } }
    public var muted: Bool
    public var ignored: Bool

    /// Spreads the useful range along the track: 50% is -18 dB, 25% is -36 dB, and the ends stay at 0 and 1.
    private static let gainCurveExponent: Double = 3

    init(volume: Double = 1, muted: Bool = false, ignored: Bool = false) {
        self.volume = Self.clamped(volume)
        self.muted = muted
        self.ignored = ignored
    }

    private static func clamped(_ volume: Double) -> Double { volume.isFinite ? min(1, max(0, volume)) : 1 }

    public var needsProcessing: Bool { !ignored && (muted || volume < 1) }
    var effectiveGain: Float { muted ? 0 : Float(pow(volume, Self.gainCurveExponent)) }
}

extension AppAdjustment {
    /// A missing field takes its default, so adding a field cannot lose saved levels.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
                  muted: try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  ignored: try container.decodeIfPresent(Bool.self, forKey: .ignored) ?? false)
    }
}

public struct AudioClientSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    let bundleIdentifier: String?
    let applicationURL: URL?
    public let processObjectIDs: [UInt32]
    public let isRunningOutput: Bool
    public let isControllable: Bool
    public let unavailableReason: String?
    let isAdjustmentApplied: Bool
    let isAdjustmentPending: Bool
    /// A failed pipeline that another attempt could fix. A rejected route is not one.
    let canRetry: Bool
    /// False for a process known only by a PID-based ID, which must not be saved.
    let hasStableIdentity: Bool

    init(id: String, name: String, bundleIdentifier: String? = nil, applicationURL: URL? = nil,
         processObjectIDs: [UInt32] = [], isRunningOutput: Bool,
         isControllable: Bool = true, unavailableReason: String? = nil, isAdjustmentApplied: Bool = true,
         isAdjustmentPending: Bool = false, canRetry: Bool = false, hasStableIdentity: Bool = true) {
        self.id = id; self.name = name; self.bundleIdentifier = bundleIdentifier; self.applicationURL = applicationURL
        self.processObjectIDs = processObjectIDs; self.isRunningOutput = isRunningOutput
        self.isControllable = isControllable; self.unavailableReason = unavailableReason
        self.isAdjustmentApplied = isAdjustmentApplied
        self.isAdjustmentPending = isAdjustmentPending
        self.canRetry = canRetry; self.hasStableIdentity = hasStableIdentity
    }
}

public struct AudioOutputSnapshot: Identifiable, Equatable, Sendable {
    public let id: UInt32
    let uid: String
    public let name: String
    public let volume: Double?
    public let muted: Bool?
    let iconURL: URL?
    public let identity: AudioOutputIdentity

    init(id: UInt32, uid: String, name: String, volume: Double? = nil, muted: Bool? = nil, iconURL: URL? = nil,
         identity: AudioOutputIdentity = .unknown) {
        self.id = id; self.uid = uid; self.name = name; self.volume = volume; self.muted = muted; self.iconURL = iconURL
        self.identity = identity
    }

    func withLevels(volume: Double?, muted: Bool?) -> Self {
        Self(id: id, uid: uid, name: name, volume: volume, muted: muted, iconURL: iconURL, identity: identity)
    }
}

public struct AudioSnapshot: Equatable, Sendable {
    public var clients: [AudioClientSnapshot]
    public var outputs: [AudioOutputSnapshot]
    public var defaultOutputID: UInt32?
    public var accessState: AudioAccessState
    /// Why the current output cannot run app levels at all, with or without clients.
    public var outputUnsupportedReason: String?

    public init(clients: [AudioClientSnapshot] = [], outputs: [AudioOutputSnapshot] = [], defaultOutputID: UInt32? = nil,
                accessState: AudioAccessState = .notRequested, outputUnsupportedReason: String? = nil) {
        self.clients = clients; self.outputs = outputs; self.defaultOutputID = defaultOutputID
        self.accessState = accessState; self.outputUnsupportedReason = outputUnsupportedReason
    }
}

public enum AudioAccessState: Equatable, Sendable {
    case notRequested, waitingForAudio, verified, denied
}

/// Control-plane methods run on the main actor. Audio callbacks stay in the C target.
@MainActor
public protocol AudioBackend: AnyObject {
    var onSnapshot: ((AudioSnapshot) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func startMonitoring() throws
    /// Explicit intent to use audio access. Verification continues through snapshot accessState;
    /// silence is a waiting state. A nonmuting tap may request access once output IO exists.
    func requestAccess() async throws
    /// Makes macOS ask for audio access now, without turning app levels on.
    func promptForAccess()
    /// macOS no longer allows access, so earlier proof of it no longer counts.
    func accessWasLost()
    /// Store desired values even if an app is not running; reconcile on process/output changes.
    func setAdjustment(_ adjustment: AppAdjustment, for clientID: String)
    func removeAdjustment(for clientID: String)
    func setProcessingEnabled(_ enabled: Bool) throws
    func selectOutput(_ deviceID: UInt32) throws
    /// Output writes name the device the user was looking at. If it is no longer the live
    /// default the write is dropped silently, so a switch mid-drag cannot set the new device.
    func setOutputVolume(_ volume: Double, for deviceID: UInt32) throws
    func setOutputMuted(_ muted: Bool, for deviceID: UInt32) throws
    func stop()
    /// Waits up to `timeout` for teardown queued by `stop()`. A HAL call can be waiting on
    /// consent, so this is best-effort.
    func drain(timeout: TimeInterval)
}
