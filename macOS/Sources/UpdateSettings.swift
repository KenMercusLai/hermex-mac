import Combine
import Sparkle

/// Sparkle owns persistence and defaults; never reset user choices on startup.
@MainActor final class UpdateSettings: ObservableObject {
    let updater: SPUUpdater
    @Published private(set) var canCheck = false
    @Published private(set) var checksEnabled = false
    @Published private(set) var installsEnabled = false

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksEnabled)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$installsEnabled)
    }

    func checkForUpdates() { updater.checkForUpdates() }
}
