import Foundation
import Testing
@testable import DamperCore

private struct Outage: Error {}

@MainActor
private final class Harness {
    let scheduler: RefreshScheduler
    var attempts = 0
    var failingAttempts = Int.max
    var failures: [Bool] = []

    init(retryDelays: [Duration]) {
        scheduler = RefreshScheduler(debounce: .milliseconds(1), retryDelays: retryDelays)
        scheduler.perform = { [unowned self] in
            attempts += 1
            if attempts <= failingAttempts { throw Outage() }
        }
        scheduler.failed = { [unowned self] _, final in failures.append(final) }
    }

    func wait(until condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }
}

@MainActor @Test func aRetryThatSucceedsReportsNoFinalFailureAndResetsTheCount() async throws {
    let harness = Harness(retryDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    harness.failingAttempts = 2
    harness.scheduler.signal()
    try await harness.wait { harness.attempts == 3 }
    #expect(harness.failures == [false, false])

    // The earlier failures no longer count: a new outage gets every retry again.
    harness.failingAttempts = .max; harness.attempts = 0; harness.failures = []
    harness.scheduler.signal()
    try await harness.wait { harness.failures.count == 4 }
    #expect(harness.failures == [false, false, false, true])
}

@MainActor @Test func exhaustedRetriesReportOnceAndThenStop() async throws {
    let harness = Harness(retryDelays: [.milliseconds(1), .milliseconds(1)])
    harness.scheduler.signal()
    try await harness.wait { harness.failures.contains(true) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(harness.attempts == 3)
    #expect(harness.failures == [false, false, true])
}

@MainActor @Test func aNewSignalReplacesASleepingRetry() async throws {
    let harness = Harness(retryDelays: [.seconds(3600)])
    harness.failingAttempts = 1
    harness.scheduler.signal()
    try await harness.wait { harness.attempts == 1 }
    harness.scheduler.signal()
    try await harness.wait { harness.attempts == 2 }
    #expect(harness.failures == [false])
}

@MainActor @Test func repeatedSignalsCoalesceIntoOneRefresh() async throws {
    let harness = Harness(retryDelays: [])
    harness.failingAttempts = 0
    for _ in 0..<5 { harness.scheduler.signal() }
    try await harness.wait { harness.attempts == 1 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(harness.attempts == 1)
}

@MainActor @Test func cancellingStopsAPendingRetry() async throws {
    let harness = Harness(retryDelays: [.milliseconds(5)])
    harness.scheduler.signal()
    try await harness.wait { harness.attempts == 1 }
    harness.scheduler.cancel()
    try await Task.sleep(for: .milliseconds(30))
    #expect(harness.attempts == 1)
    #expect(harness.failures == [false])
}
