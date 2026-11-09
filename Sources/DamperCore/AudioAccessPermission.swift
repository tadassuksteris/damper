import Foundation

public enum AudioAccessPermission: String, Equatable, Sendable {
    case allowed, denied, notAsked
    /// macOS no longer offers the check, or the app was built without it.
    case unavailable
}

@MainActor
protocol AudioAccessPermissionProviding {
    var current: AudioAccessPermission { get }
    /// The answer as of now, or nil if it couldn't be found out. `current` can stay stale for the
    /// life of a process, so it is no substitute.
    func fresh() async -> AudioAccessPermission?
    func request(completion: @escaping @MainActor (AudioAccessPermission) -> Void)
}

/// The one use of private API in the app, because no public API can read or request this
/// permission. It reports and asks. Levels still start only from real audio, but a report that
/// access was lost stops them. The functions are looked up at run time so that macOS removing
/// them means `.unavailable`, not a crash.
/// `./scripts/build.sh release -Xswiftc -DDAMPER_NO_PRIVATE_TCC` leaves it out.
public struct SystemAudioAccessPermission: AudioAccessPermissionProviding {
    nonisolated static let statusArgument = "--audio-access-status"
    nonisolated static let requestArgument = "--audio-access-request"
    /// A fresh process stops waiting for an answer after this, in case its parent has gone.
    nonisolated static let requestTimeout: TimeInterval = 300

    /// Answers for a short-lived copy of this executable. True if this launch was one of those.
    public static func handleFreshProcessArguments() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains(statusArgument) {
            print(SystemAudioAccessPermission().current.rawValue)
            return true
        }
        guard arguments.contains(requestArgument) else { return false }
        print(SystemAudioAccessPermission().requestAndWait().rawValue)
        return true
    }

    #if DAMPER_NO_PRIVATE_TCC
    var current: AudioAccessPermission { .unavailable }
    private func requestAndWait() -> AudioAccessPermission { .unavailable }
    func fresh() async -> AudioAccessPermission? { .unavailable }
    func request(completion: @escaping @MainActor (AudioAccessPermission) -> Void) { completion(.unavailable) }
    #else
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let found = dlsym(library, name) else { return nil }
        return unsafeBitCast(found, to: type)
    }

    var current: AudioAccessPermission {
        guard let preflight = Self.symbol("TCCAccessPreflight", as: Preflight.self) else { return .unavailable }
        switch preflight(Self.service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .notAsked
        }
    }

    /// macOS caches the answer inside a process until it exits, so a change in System Settings
    /// never reaches `current`. A short-lived copy of this executable has no cache to go stale.
    func fresh() async -> AudioAccessPermission? {
        await Task.detached(priority: .utility) { Self.askFreshProcess(Self.statusArgument, timeout: 10) }.value
    }

    /// The child is killed after `timeout`, so a TCC call that never returns can't hang the caller.
    private nonisolated static func askFreshProcess(_ argument: String, timeout: TimeInterval) -> AudioAccessPermission? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return AudioAccessPermission(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Asks from a fresh process too: this process's cache can answer without showing a prompt.
    func request(completion: @escaping @MainActor (AudioAccessPermission) -> Void) {
        Task { @MainActor in
            let answer = await Task.detached(priority: .userInitiated) { Self.askFreshProcess(Self.requestArgument, timeout: Self.requestTimeout + 10) }.value
            completion(answer ?? .unavailable)
        }
    }

    private func requestAndWait() -> AudioAccessPermission {
        guard let request = Self.symbol("TCCAccessRequest", as: Request.self) else { return .unavailable }
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted: Bool?
        request(Self.service, nil) { answer in
            granted = answer
            answered.signal()
        }
        guard answered.wait(timeout: .now() + Self.requestTimeout) == .success, let granted else { return current }
        return granted ? .allowed : .denied
    }
    #endif
}
