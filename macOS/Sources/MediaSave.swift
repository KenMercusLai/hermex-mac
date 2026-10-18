import AppKit
import Foundation
import Darwin

@MainActor enum MediaSave {
    typealias Selector = (String) async -> URL?
    static func chooseDestination(filename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.prompt = "Download"
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = false
        panel.isExtensionHidden = false
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    /// The only pre-confirmation action is the selector. No request, temporary
    /// file, directory creation or destination inspection happens on cancel.
    @discardableResult static func perform(reference: MediaReference, select: Selector,
        isCurrent: () -> Bool, fetch: () async throws -> URL) async throws -> Bool {
        guard let destination = await select(reference.filename) else { return false }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let temporary = try await fetch()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard destination.isFileURL else { throw MacFailure.message("Choose a local save destination.") }
        // Stage on the destination volume, then POSIX rename is an atomic replace.
        // Existing files survive failed requests, copies and rename failures.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".hermex-download-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        guard rename(staged.path, destination.path) == 0 else { throw MacFailure.message("The download could not be saved at the chosen location.") }
        return true
    }
}
