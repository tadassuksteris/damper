import Foundation
import Testing
@testable import DamperCore

@Test func systemServicesRemainHiddenAtSimulatorAndCryptexPaths() {
    let paths = [
        "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
        "/System/Library/Frameworks/AudioToolbox.framework/systemsoundserverd",
        "/Library/Apple/System/Library/Frameworks/AudioToolbox.framework/systemsoundserverd",
        "/private/var/run/com.apple.security.cryptexd/mnt/iOS/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/AudioToolbox.framework/systemsoundserver-simd",
        "/private/preboot/Cryptexes/OS/System/Library/CoreServices/example"
    ]
    for path in paths { #expect(AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: path))) }
    #expect(AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: osCryptexWebKitGPU)))
    #expect(!AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: "/Applications/Player.app/Contents/MacOS/Player")))
    #expect(!AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: "/usr/bin/afplay")))
}

private let webKitGPUSuffix = "System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
private let osCryptexWebKitGPU = "/System/Volumes/Preboot/Cryptexes/OS/" + webKitGPUSuffix

@Test func appleUserApplicationsAreNotSystemServices() {
    let paths = [
        "/System/Applications/Music.app/Contents/MacOS/Music",
        "/System/Applications/Utilities/Audio MIDI Setup.app/Contents/MacOS/Audio MIDI Setup",
        "/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
        "/private/preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
    ]
    for path in paths { #expect(!AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: path))) }
    // The exemption is for those roots only, not any path that mentions them.
    #expect(AudioApplicationIdentity.isSystemServiceExecutable(URL(fileURLWithPath: "/System/Library/CoreServices/System/Applications/Example.app/Contents/MacOS/Example")))
}

@Test func theWebKitGPUProcessNeedsBothItsBundleIDAndItsSystemPath() {
    let identified = "com.apple.WebKit.GPU"
    for path in ["/" + webKitGPUSuffix, osCryptexWebKitGPU, "/private/preboot/Cryptexes/OS/" + webKitGPUSuffix] {
        #expect(AudioApplicationIdentity.isWebKitGPUProcess(executable: URL(fileURLWithPath: path), audioBundleID: identified))
        #expect(!AudioApplicationIdentity.isWebKitGPUProcess(executable: URL(fileURLWithPath: path), audioBundleID: "org.example.player"))
        #expect(!AudioApplicationIdentity.isWebKitGPUProcess(executable: URL(fileURLWithPath: path), audioBundleID: nil))
    }
    for path in ["/Users/example/" + webKitGPUSuffix, "/Applications/Player.app/Contents/MacOS/com.apple.WebKit.GPU",
                 "/System/Library/CoreServices/com.apple.WebKit.GPU"] {
        #expect(!AudioApplicationIdentity.isWebKitGPUProcess(executable: URL(fileURLWithPath: path), audioBundleID: identified))
    }
}

@Test func audioIdentityGroupsNestedHelpersByValidatedOuterApplicationPath() {
    let outer = URL(fileURLWithPath: "/Applications/Browser.app")
    let helper = outer.appendingPathComponent("Contents/Frameworks/Browser Helper.app")
    let executable = helper.appendingPathComponent("Contents/MacOS/Browser Helper")
    let result = AudioApplicationIdentity.enclosingApplication(executable: executable) { url in
        switch url.path {
        case outer.path: ("org.example.browser", outer.appendingPathComponent("Contents/MacOS/Browser"), "Browser")
        case helper.path: ("org.example.browser.helper.renderer", executable, "Browser Helper")
        default: nil
        }
    }
    #expect(result?.id == "org.example.browser"); #expect(result?.url.path == outer.path); #expect(result?.name == "Browser")
}
@Test func audioIdentityDoesNotInventParentFromSuffixOrTerminalAncestry() {
    let helper = URL(fileURLWithPath: "/Applications/Standalone Helper.app")
    let executable = helper.appendingPathComponent("Contents/MacOS/Helper")
    let result = AudioApplicationIdentity.enclosingApplication(executable: executable) { url in
        url.path == helper.path ? ("org.example.helper.renderer", executable, "Standalone Helper") : nil
    }
    #expect(result?.id == "org.example.helper.renderer")
    #expect(AudioApplicationIdentity.enclosingApplication(executable: URL(fileURLWithPath: "/opt/homebrew/bin/player"), bundleAt: { _ in nil }) == nil)
}
@Test func audioIdentityRequiresBundleExecutableContainedInTheApp() {
    let app = URL(fileURLWithPath: "/Applications/False.app")
    #expect(AudioApplicationIdentity.enclosingApplication(executable: app.appendingPathComponent("Contents/MacOS/Helper")) { url in
        url.path == app.path ? ("org.example.false", URL(fileURLWithPath: "/usr/bin/false"), "False") : nil
    } == nil)
    #expect(AudioApplicationIdentity.enclosingApplication(executable: URL(fileURLWithPath: "/Applications/Browser.app.backup/player")) { _ in
        ("org.example.browser", URL(fileURLWithPath: "/Applications/Browser.app/Contents/MacOS/Browser"), "Browser")
    } == nil)
}

@Test func audioIdentityAcceptsRunningAppMetadataWithoutReadingItsBundle() {
    let bundle = URL(fileURLWithPath: "/Users/example/Code/Damper Test.app")
    let executable = bundle.appendingPathComponent("Contents/MacOS/AudioFixture")
    let result = AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
        bundleURL: bundle, bundleID: "org.example.fixture", name: "Audio Fixture", audioBundleID: "org.example.fixture")
    #expect(result?.id == "org.example.fixture")
    #expect(result?.name == "Audio Fixture")
    #expect(result?.url.path == bundle.path)
    let noAudioID = AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
        bundleURL: bundle, bundleID: "org.example.fixture", name: nil, audioBundleID: nil)
    #expect(noAudioID?.name == "Damper Test")
}

@Test func audioIdentityRejectsRunningAppMetadataThatDoesNotMatchTheProcess() {
    let bundle = URL(fileURLWithPath: "/Users/example/Code/Player.app")
    let executable = bundle.appendingPathComponent("Contents/MacOS/Player")
    let helper = bundle.appendingPathComponent("Contents/Helpers/Helper")
    let otherBundle = URL(fileURLWithPath: "/Users/example/Code/Other.app")
    #expect(AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: helper,
        bundleURL: bundle, bundleID: "org.example.player", name: "Player", audioBundleID: "org.example.player") == nil)
    #expect(AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
        bundleURL: otherBundle, bundleID: "org.example.player", name: "Player", audioBundleID: "org.example.player") == nil)
    for audioID in ["org.example.other", "org.example.player.helper", ""] {
        #expect(AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
            bundleURL: bundle, bundleID: "org.example.player", name: "Player", audioBundleID: audioID) == nil)
    }
}

@Test func audioIdentityRejectsExecutableOutsideTheReportedRunningApp() {
    let bundle = URL(fileURLWithPath: "/Users/example/Code/Player.app")
    for executable in [URL(fileURLWithPath: "/usr/bin/afplay"),
                       URL(fileURLWithPath: "/Users/example/Code/Player.app.backup/Contents/MacOS/Player"),
                       bundle.appendingPathComponent("../Other.app/Contents/MacOS/Player")] {
        #expect(AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
            bundleURL: bundle, bundleID: "org.example.player", name: "Player", audioBundleID: "org.example.player") == nil)
    }
    let nonApp = URL(fileURLWithPath: "/Users/example/Code/Player")
    let executable = nonApp.appendingPathComponent("Contents/MacOS/Player")
    #expect(AudioApplicationIdentity.runningApplication(executable: executable, reportedExecutable: executable,
        bundleURL: nonApp, bundleID: "org.example.player", name: "Player", audioBundleID: "org.example.player") == nil)
}

@Test func audioIdentityRejectsMissingOrNonfileRunningAppMetadata() {
    let bundle = URL(fileURLWithPath: "/Users/example/Code/Player.app")
    let executable = bundle.appendingPathComponent("Contents/MacOS/Player")
    let cases: [(URL?, URL?, URL?, String?)] = [
        (nil, executable, bundle, "org.example.player"),
        (executable, nil, bundle, "org.example.player"),
        (executable, executable, nil, "org.example.player"),
        (executable, executable, bundle, nil),
        (executable, executable, bundle, ""),
        (URL(string: "https://example.com/Player.app/Contents/MacOS/Player"), executable, bundle, "org.example.player"),
        (executable, URL(string: "https://example.com/Player.app/Contents/MacOS/Player"), bundle, "org.example.player"),
        (executable, executable, URL(string: "https://example.com/Player.app"), "org.example.player")
    ]
    for (actual, reported, appURL, bundleID) in cases {
        #expect(AudioApplicationIdentity.runningApplication(executable: actual, reportedExecutable: reported,
            bundleURL: appURL, bundleID: bundleID, name: "Player", audioBundleID: nil) == nil)
    }
}
