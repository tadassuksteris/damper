import AppKit
import Darwin
import Foundation

struct ValidatedAudioApplication: Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
}

/// Apps are identified by which bundle contains their executable, not by bundle ID suffixes.
enum AudioApplicationIdentity {
    /// Apple's user-facing apps, including the cryptex locations Safari runs from.
    private static let systemApplicationRoots = [
        "/System/Applications/",
        "/System/Cryptexes/App/System/Applications/",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/",
        "/private/preboot/Cryptexes/App/System/Applications/"
    ]

    static func isSystemServiceExecutable(_ executable: URL) -> Bool {
        let path = executable.standardizedFileURL.path
        if systemApplicationRoots.contains(where: path.hasPrefix) { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/System/") ||
            path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") { return true }
        // Simulator services and cryptex mounts can report a private host path instead of /System.
        if path.contains(".simruntime/Contents/Resources/RuntimeRoot/System/") { return true }
        if (path.hasPrefix("/private/preboot/") || path.hasPrefix("/private/var/run/com.apple.security.cryptexd/")) &&
            path.contains("/System/") { return true }
        return false
    }
    /// WebKit's shared GPU process plays media for Safari, Mail and other WebKit hosts. Nothing
    /// public names the app behind it, so it gets one explanatory row rather than a guessed parent.
    static func isWebKitGPUProcess(executable: URL, audioBundleID: String?) -> Bool {
        let path = executable.standardizedFileURL.path
        return audioBundleID == "com.apple.WebKit.GPU" && isSystemServiceExecutable(executable) &&
            path.contains("/System/Library/Frameworks/WebKit.framework/") &&
            path.hasSuffix("/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
    }
    static func enclosingApplication(executable: URL, bundleAt: (URL) -> (id: String, executable: URL, name: String)?) -> ValidatedAudioApplication? {
        let executable = executable.standardizedFileURL.resolvingSymlinksInPath()
        var cursor = executable.deletingLastPathComponent()
        // Walks all the way to / and keeps the outermost .app. Chrome, Slack and other Chromium-based
        // apps play sound from helper apps nested inside their bundle, and those must share the
        // main app's ID and row.
        var candidate: ValidatedAudioApplication?
        while cursor.path != "/" {
            if cursor.pathExtension.lowercased() == "app", let bundle = bundleAt(cursor), !bundle.id.isEmpty {
                let main = bundle.executable.standardizedFileURL.resolvingSymlinksInPath()
                // A real app has an executable inside its own bundle; a directory named *.app is insufficient.
                if main.path.hasPrefix(cursor.path + "/"), executable.path.hasPrefix(cursor.path + "/") {
                    candidate = ValidatedAudioApplication(id: bundle.id, name: bundle.name, url: cursor)
                }
            }
            cursor.deleteLastPathComponent()
        }
        return candidate
    }

    /// Launch Services can identify a running app even when the sandbox cannot read its bundle.
    /// Accept only that app's own executable, independently corroborated by proc_pidpath.
    static func runningApplication(executable: URL?, reportedExecutable: URL?, bundleURL: URL?,
                                   bundleID: String?, name: String?, audioBundleID: String?) -> ValidatedAudioApplication? {
        guard let executable, let reportedExecutable, let bundleURL, let bundleID, !bundleID.isEmpty,
              executable.isFileURL, reportedExecutable.isFileURL, bundleURL.isFileURL else { return nil }
        let actual = executable.standardizedFileURL.resolvingSymlinksInPath()
        let reported = reportedExecutable.standardizedFileURL.resolvingSymlinksInPath()
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.pathExtension.lowercased() == "app",
              !isSystemServiceExecutable(actual),
              actual.path == reported.path,
              actual.path.hasPrefix(bundle.path + "/"),
              reported.path.hasPrefix(bundle.path + "/"),
              audioBundleID == nil || audioBundleID == bundleID else { return nil }
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? bundle.deletingPathExtension().lastPathComponent
        return ValidatedAudioApplication(id: bundleID, name: name, url: bundle)
    }

    static func executablePath(pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @MainActor static func resolve(pid: pid_t, audioBundleID: String?) -> ValidatedAudioApplication? {
        let app = NSRunningApplication(processIdentifier: pid)
        let processExecutable = executablePath(pid: pid).map { URL(fileURLWithPath: $0) }
        let executable = processExecutable ?? app?.executableURL
        guard let executable, !isSystemServiceExecutable(executable) else { return nil }
        let resolved = enclosingApplication(executable: executable) { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, let executable = bundle.executableURL else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return (id, executable, name)
        }
        guard let resolved else {
            // The sandbox can block reading bundles outside the usual app folders. This fallback
            // can't group helpers.
            guard let app, app.processIdentifier == pid, !app.isTerminated else { return nil }
            return runningApplication(executable: processExecutable, reportedExecutable: app.executableURL,
                bundleURL: app.bundleURL, bundleID: app.bundleIdentifier, name: app.localizedName, audioBundleID: audioBundleID)
        }
        // Corroborate process metadata against the process's innermost real bundle or running-app identity.
        if let audioBundleID, !audioBundleID.isEmpty {
            var cursor = executable.deletingLastPathComponent()
            var verified = app?.bundleIdentifier == audioBundleID
            while cursor.path != "/" {
                if Bundle(url: cursor)?.bundleIdentifier == audioBundleID { verified = true; break }
                cursor.deleteLastPathComponent()
            }
            guard verified else { return nil }
        }
        return resolved
    }
}
