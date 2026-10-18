import Foundation

/// Foundation can ignore TMPDIR under SwiftPM's test runner. Use the configured
/// Hermes scratch root explicitly for every new MEDIA test artifact and process.
enum MediaTestSupport {
    static var scratch: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERMEX_SCRATCH"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch").path,
            isDirectory: true)
    }
}
