import AppKit
import Combine
import Sparkle
import SwiftUI

/// One updater per app lifetime, independent of authentication/server settings.
@MainActor final class UpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var subscriptions = Set<AnyCancellable>()
    private let gate: UpdateRestartGate
    private weak var store: MacStore?
    private var updateTerminationPending = false
    private var terminationCompletion: ((Bool) -> Void)?
    var shouldDeferUpdateTermination: Bool {
        updateTerminationPending && (store?.busy == true || store?.streaming == true || store?.streamID != nil)
    }
    private(set) var settings: UpdateSettings!
    @Published private(set) var startupError: String?
    var updater: SPUUpdater { controller.updater }

    init(store: MacStore, start: Bool = true) {
        self.store = store
        gate = UpdateRestartGate(isBusy: { [weak store] in
            guard let store else { return false }
            return store.busy || store.streaming || store.streamID != nil
        })
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        settings = UpdateSettings(updater: updater)
        Publishers.CombineLatest3(store.$busy, store.$streaming, store.$streamID)
            .sink { [weak self] _ in
                // Published sends before the store changes; recheck on main actor
                // after the mutation, including any intervening new activity.
                Task { @MainActor [weak self] in self?.resumeDeferredUpdate() }
            }.store(in: &subscriptions)
        if start {
            do { try updater.start() }
            catch { startupError = "Automatic updates unavailable: \(error.localizedDescription)" }
        }
    }

    // Keep AppKit's outstanding termination request, rather than canceling it:
    // Sparkle's postponement continuation is one-shot and cannot request it again.
    func deferTermination(untilIdle completion: @escaping (Bool) -> Void) -> Bool {
        guard shouldDeferUpdateTermination else { return false }
        if terminationCompletion == nil { terminationCompletion = completion }
        return true
    }

    private func resumeDeferredUpdate() {
        gate.resumeIfIdle()
        guard !shouldDeferUpdateTermination, let completion = terminationCompletion else { return }
        terminationCompletion = nil
        completion(true)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { updateTerminationPending = true }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { updateTerminationPending = true }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        updateTerminationPending = false
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?(false)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.postpone(installHandler)
    }
}

/// Defense in depth if new work starts after Sparkle's one-shot postponement.
@MainActor final class HermexAppDelegate: NSObject, NSApplicationDelegate {
    weak var updates: UpdateCoordinator?
    var terminationReply: (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates?.deferTermination(untilIdle: terminationReply) == true ? .terminateLater : .terminateNow
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var coordinator: UpdateCoordinator
    @ObservedObject var settings: UpdateSettings
    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Updates").font(.headline)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { settings.automaticallyChecks }, set: { settings.automaticallyChecks = $0 }))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { settings.automaticallyInstalls }, set: { settings.automaticallyInstalls = $0 }))
                .disabled(!settings.checksEnabled)
            Button("Check for Updates…") { settings.checkForUpdates() }.disabled(!settings.canCheck)
            Text("Checks GitHub Releases daily. Downloads are verified with the app's Ed25519 public key before extraction. Automatic installation completes when you quit; an update restart waits for active work to finish.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = coordinator.startupError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct CheckForAppUpdates: View {
    @ObservedObject var settings: UpdateSettings
    var body: some View {
        Button("Check for Updates…") { settings.checkForUpdates() }.disabled(!settings.canCheck)
    }
}
