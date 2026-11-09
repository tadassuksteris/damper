import Foundation
import Testing
@testable import DamperCore

private let preferenceKey = "damper.preferences.v1"

@MainActor private func seeded(_ json: String) -> InMemoryPreferences {
    let defaults = InMemoryPreferences()
    defaults.set(Data(json.utf8), forKey: preferenceKey)
    return defaults
}

@MainActor @Test func preferencesSurviveRelaunchAndCanBeRemoved() {
    let defaults = InMemoryPreferences()
    let first = PreferenceStore(defaults: defaults)
    first.save(AppAdjustment(volume: 0.37, muted: true), for: "org.example.player")
    first.setActivation(hasEnabled: true, paused: true)
    first.noteAccessVerified()
    first.noteWelcomeShown()
    let reopened = PreferenceStore(defaults: defaults)
    #expect(reopened.apps["org.example.player"] == AppAdjustment(volume: 0.37, muted: true))
    #expect(reopened.hasEnabled && reopened.paused && reopened.hasVerifiedAccess && reopened.welcomeShown)
    reopened.remove("org.example.player")
    #expect(PreferenceStore(defaults: defaults).apps.isEmpty)
}

/// Guards the stored format: a schema change that breaks this data would lose every saved level.
@MainActor @Test func theOriginalStoredFormatKeepsLoading() {
    let store = PreferenceStore(defaults: seeded("""
        {"apps":{"org.example.player":{"volume":0.37,"muted":true,"ignored":false},\
        "org.example.chat":{"volume":1,"muted":false,"ignored":true}},"hasEnabled":true,"paused":true}
        """))
    #expect(store.apps["org.example.player"] == AppAdjustment(volume: 0.37, muted: true))
    #expect(store.apps["org.example.chat"] == AppAdjustment(ignored: true))
    #expect(store.hasEnabled && store.paused)
    #expect(!store.hasVerifiedAccess && !store.welcomeShown)
}

@MainActor @Test func storedVolumesAreClampedOnLoad() {
    let store = PreferenceStore(defaults: seeded("""
        {"apps":{"high":{"volume":2,"muted":false,"ignored":false},"low":{"volume":-1,"muted":false,"ignored":false}},\
        "hasEnabled":true,"paused":false}
        """))
    #expect(store.apps["high"]?.volume == 1)
    #expect(store.apps["low"]?.volume == 0)
}

@MainActor @Test func missingStoredFieldsKeepTheFieldsThatArePresent() {
    let entry = PreferenceStore(defaults: seeded(#"{"apps":{"org.example.player":{"muted":true}},"paused":true}"#))
    #expect(entry.apps["org.example.player"] == AppAdjustment(muted: true))
    #expect(entry.paused && !entry.hasEnabled)
    let noApps = PreferenceStore(defaults: seeded(#"{"hasEnabled":true}"#))
    #expect(noApps.apps.isEmpty && noApps.hasEnabled && !noApps.paused)
}

@MainActor @Test func undecodableDataYieldsDefaultsWithoutCrashing() {
    for garbage in ["not json", "[]", #"{"apps":3}"#, ""] {
        let store = PreferenceStore(defaults: seeded(garbage))
        #expect(store.apps.isEmpty && !store.hasEnabled && !store.paused && !store.hasVerifiedAccess)
    }
}

@MainActor @Test func savingDefaultRemovesEntry() {
    let defaults = InMemoryPreferences()
    let store = PreferenceStore(defaults: defaults)
    store.save(AppAdjustment(volume: 0.5), for: "org.example.player")
    #expect(PreferenceStore(defaults: defaults).apps["org.example.player"]?.volume == 0.5)
    store.save(AppAdjustment(), for: "org.example.player")
    #expect(PreferenceStore(defaults: defaults).apps.isEmpty)
}

@Test func invalidGainCannotEscapeTheSupportedRange() {
    #expect(AppAdjustment(volume: .nan).volume == 1)
    #expect(AppAdjustment(volume: .infinity).volume == 1)
    #expect(AppAdjustment(volume: -0.2).volume == 0)
    #expect(AppAdjustment(volume: 2).volume == 1)
    #expect(AppAdjustment(volume: 0.999).needsProcessing)
    #expect(!AppAdjustment(volume: 0.3, ignored: true).needsProcessing)
    #expect(AppAdjustment(volume: 0.7, muted: true).effectiveGain == 0)
    var assigned = AppAdjustment()
    assigned.volume = .nan
    #expect(assigned.volume == 1)
    assigned.volume = -3
    #expect(assigned.volume == 0)
    assigned.volume = .infinity
    #expect(assigned.volume == 1)
    assigned.volume = 2
    #expect(assigned.volume == 1)
    assigned.volume = 0.4
    #expect(assigned.volume == 0.4)
}

@Test func gainFollowsACubicCurveThatIsNeverLouderThanThePosition() {
    #expect(AppAdjustment(volume: 0).effectiveGain == 0)
    #expect(AppAdjustment(volume: 1).effectiveGain == 1)
    #expect(AppAdjustment(volume: 0.5).effectiveGain == 0.125)
    #expect(AppAdjustment(volume: 0.25).effectiveGain == 0.015625)
    var previous: Float = -1
    for step in 0...1000 {
        let position = Double(step) / 1000
        let gain = AppAdjustment(volume: position).effectiveGain
        #expect(gain > previous)
        #expect(gain <= Float(position))
        previous = gain
    }
}

@MainActor @Test func sliderWritesAreCoalescedAndFlushKeepsTheFinalValue() {
    let defaults = InMemoryPreferences()
    let store = PreferenceStore(defaults: defaults)
    for value in [0.6, 0.4, 0.25] {
        store.save(AppAdjustment(volume: value), for: "org.example.player", coalescing: true)
    }
    #expect(store.apps["org.example.player"]?.volume == 0.25)
    #expect(PreferenceStore(defaults: defaults).apps.isEmpty)
    store.flush()
    #expect(PreferenceStore(defaults: defaults).apps["org.example.player"]?.volume == 0.25)
}

@MainActor @Test func coalescedWriteFlushesWithoutManualFlush() async throws {
    let defaults = InMemoryPreferences()
    let store = PreferenceStore(defaults: defaults)
    store.save(AppAdjustment(volume: 0.25), for: "org.example.player", coalescing: true)
    let deadline = ContinuousClock.now + .seconds(5)
    while PreferenceStore(defaults: defaults).apps.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(PreferenceStore(defaults: defaults).apps["org.example.player"]?.volume == 0.25)
    #expect(store.apps["org.example.player"]?.volume == 0.25)
}

@MainActor @Test func unreadablePreferencesAreKeptBeforeBeingReplaced() {
    let defaults = seeded("not json")
    let store = PreferenceStore(defaults: defaults)
    #expect(store.apps.isEmpty)
    store.flush()
    #expect(defaults.data(forKey: preferenceKey + ".unreadable") == Data("not json".utf8))
}
