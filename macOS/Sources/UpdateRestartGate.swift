import Foundation

/// Keeps Sparkle's install/relaunch continuation until all local work is idle.
/// A disconnected SSE still owns an active server stream and is not idle.
@MainActor final class UpdateRestartGate {
    private let isBusy: () -> Bool
    private var pending: (() -> Void)?

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func postpone(_ install: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pending = install
        return true
    }

    func resumeIfIdle() {
        guard !isBusy(), let install = pending else { return }
        pending = nil
        install()
    }
}
