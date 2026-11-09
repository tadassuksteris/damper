/// Coalesces refresh signals, and retries a failed refresh a bounded number of times so that a
/// brief Core Audio outage recovers without being reported.
@MainActor
final class RefreshScheduler {
    var perform: () throws -> Void = {}
    /// Runs after each failed attempt. `final` is true once the retries are used up.
    var failed: (_ error: any Error, _ final: Bool) -> Void = { _, _ in }
    private let debounce: Duration
    private let retryDelays: [Duration]
    private var task: Task<Void, Never>?
    private var retryIsSleeping = false
    private var failedAttempts = 0

    init(debounce: Duration, retryDelays: [Duration]) {
        self.debounce = debounce; self.retryDelays = retryDelays
    }

    /// A new signal replaces a sleeping retry, so a restart notification is not held back by its delay.
    func signal() {
        if retryIsSleeping { clearPending() }
        guard task == nil else { return }
        schedule(after: debounce)
    }

    func cancel() {
        clearPending()
        failedAttempts = 0
    }

    private func clearPending() {
        task?.cancel(); task = nil
        retryIsSleeping = false
    }

    private func schedule(after delay: Duration) {
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.task = nil; self.retryIsSleeping = false
            do {
                try self.perform()
                self.failedAttempts = 0
            } catch {
                let final = self.failedAttempts >= self.retryDelays.count
                if final { self.failedAttempts = 0 } else {
                    self.retryIsSleeping = true
                    self.schedule(after: self.retryDelays[self.failedAttempts])
                    self.failedAttempts += 1
                }
                self.failed(error, final)
            }
        }
    }
}
