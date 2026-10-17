import Testing
import Foundation
import Sparkle

@Test @MainActor func updateSettingsUseSparklesPersistedPreferencesWithoutServerLogin() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermexUpdaterTests-\(UUID()).app")
    let contents = root.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let id = "com.kenmercuslai.hermex-mac.update-tests.\(UUID())"
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: id) }
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleVersion": "0.1.2", "CFBundlePackageType": "APPL",
                               "CFBundleName": "Hermex Test", "CFBundleExecutable": "Test",
                               "SUFeedURL": "https://fixture.invalid/appcast.xml",
                               "SUPublicEDKey": "ZGKYOJFq64vV2b/pVsWRMfY+crWyV8PWy1l/xMKK0Xg=",
                               "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: root))
    let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                             userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    let settings = UpdateSettings(updater: updater)
    #expect(settings.automaticallyChecks)
    #expect(settings.automaticallyInstalls)
    settings.automaticallyChecks = false
    settings.automaticallyInstalls = false
    #expect(!updater.automaticallyChecksForUpdates)
    #expect(!updater.automaticallyDownloadsUpdates)
    let reloaded = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                              userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    #expect(!reloaded.automaticallyChecksForUpdates)
    #expect(!reloaded.automaticallyDownloadsUpdates)
}

@Test @MainActor func sparkleDelegateResumesPostponedInstallOnlyAfterStoreBecomesIdle() async {
    let store = MacStore(persistence: false)
    let coordinator = UpdateCoordinator(store: store, start: false)
    store.busy = true
    var installs = 0
    let item = SUAppcastItem(dictionary: ["title": "Test", "link": "https://fixture.invalid", "sparkle:version": "0.1.3",
                                          "enclosure": ["url": "https://fixture.invalid/update.zip", "sparkle:version": "0.1.3"]])!
    let delegate: SPUUpdaterDelegate = coordinator
    #expect(delegate.updater?(coordinator.updater, shouldPostponeRelaunchForUpdate: item,
                              untilInvokingBlock: { installs += 1 }) == true)
    store.busy = false
    store.streamID = "active"
    try? await Task.sleep(for: .milliseconds(30))
    #expect(installs == 0)
    store.streamID = nil
    try? await Task.sleep(for: .milliseconds(30))
    #expect(installs == 1)
}

@Test @MainActor func updateTerminationGuardCoversWorkStartingAfterPostponementEnds() async {
    let store = MacStore(persistence: false)
    let coordinator = UpdateCoordinator(store: store, start: false)
    let appDelegate = HermexAppDelegate()
    appDelegate.updates = coordinator
    var replies: [Bool] = []
    appDelegate.terminationReply = { replies.append($0) }
    store.busy = true
    let item = SUAppcastItem(dictionary: ["title": "Test", "link": "https://fixture.invalid", "sparkle:version": "0.1.3",
                                          "enclosure": ["url": "https://fixture.invalid/update.zip", "sparkle:version": "0.1.3"]])!
    var installs = 0
    let sparkle: SPUUpdaterDelegate = coordinator
    #expect(sparkle.updater?(coordinator.updater, shouldPostponeRelaunchForUpdate: item,
                            untilInvokingBlock: { installs += 1 }) == true)
    store.busy = false
    try? await Task.sleep(for: .milliseconds(30))
    #expect(installs == 1)
    store.busy = true // Work begins after Sparkle's one-shot handler has run.
    // Ordinary Quit is not intercepted merely because a run exists.
    #expect(appDelegate.applicationShouldTerminate(.shared) == .terminateNow)
    let delegate: SPUUpdaterDelegate = coordinator
    delegate.updaterWillRelaunchApplication?(coordinator.updater)
    #expect(appDelegate.applicationShouldTerminate(.shared) == .terminateLater)
    store.busy = false
    store.streamID = "active-after-gate-resumed"
    try? await Task.sleep(for: .milliseconds(30))
    #expect(replies.isEmpty)
    #expect(appDelegate.applicationShouldTerminate(.shared) == .terminateLater)
    store.streamID = nil
    try? await Task.sleep(for: .milliseconds(30))
    #expect(replies == [true])
    store.busy = true
    store.busy = false
    try? await Task.sleep(for: .milliseconds(30))
    #expect(replies == [true])
    #expect(installs == 1)
    #expect(appDelegate.applicationShouldTerminate(.shared) == .terminateNow)
}

@Test @MainActor func canceledUpdateResolvesDeferredTerminationWithoutQuitting() async {
    let store = MacStore(persistence: false)
    let coordinator = UpdateCoordinator(store: store, start: false)
    let appDelegate = HermexAppDelegate()
    appDelegate.updates = coordinator
    var replies: [Bool] = []
    appDelegate.terminationReply = { replies.append($0) }
    store.busy = true
    let delegate: SPUUpdaterDelegate = coordinator
    delegate.updaterWillRelaunchApplication?(coordinator.updater)
    #expect(appDelegate.applicationShouldTerminate(.shared) == .terminateLater)
    delegate.updater?(coordinator.updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: "test-cancel", code: 1))
    #expect(replies == [false])
    store.busy = false
    try? await Task.sleep(for: .milliseconds(30))
    #expect(replies == [false])
}

@Test @MainActor func finishedUpdateCycleDoesNotKeepInterceptingOrdinaryQuit() {
    let store = MacStore(persistence: false)
    let coordinator = UpdateCoordinator(store: store, start: false)
    let delegate: SPUUpdaterDelegate = coordinator
    delegate.updaterWillRelaunchApplication?(coordinator.updater)
    store.busy = true
    #expect(coordinator.shouldDeferUpdateTermination)
    delegate.updater?(coordinator.updater, didFinishUpdateCycleFor: .updates, error: nil)
    #expect(!coordinator.shouldDeferUpdateTermination)
}

@testable import HermexMac

@Test @MainActor func updateRestartWaitsForBusyAndDisconnectedActiveStream() {
    let store = MacStore(persistence: false)
    let gate = UpdateRestartGate(isBusy: { store.busy || store.streaming || store.streamID != nil })
    var installations = 0
    store.busy = true
    #expect(gate.postpone { installations += 1 })
    gate.resumeIfIdle()
    #expect(installations == 0)
    store.busy = false
    store.streamID = "still-running-on-server"
    store.streamDisconnected = true
    gate.resumeIfIdle()
    #expect(installations == 0)
    store.streamID = nil
    store.streaming = true
    gate.resumeIfIdle()
    #expect(installations == 0)
    store.streaming = false
    gate.resumeIfIdle()
    gate.resumeIfIdle()
    #expect(installations == 1)
    #expect(!gate.postpone { installations += 1 })
    #expect(installations == 1)
}
