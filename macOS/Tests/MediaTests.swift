import Foundation
import Testing
@testable import HermexMac

@Test @MainActor func saveCancelHasNoFetchOrWrites() async throws {
    let folder = MediaTestSupport.scratch.appendingPathComponent("media-cancel-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var fetches = 0
    let result = try await MediaSave.perform(reference: MediaReference(source: "/srv/result.zip")!,
        select: { _ in nil }, isCurrent: { true }, fetch: {
            fetches += 1
            return folder.appendingPathComponent("should-not-exist")
        })
    #expect(result == false)
    #expect(fetches == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}


@Test @MainActor func confirmedSaveReplacesAtomicallyAndFailurePreservesExistingFile() async throws {
    let folder = MediaTestSupport.scratch.appendingPathComponent("media-save-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("chosen.zip"), temporary = folder.appendingPathComponent("download.tmp")
    try Data("old".utf8).write(to: destination)
    var confirmed = false
    let saved = try await MediaSave.perform(reference: MediaReference(source: "/srv/result.zip")!,
        select: { name in #expect(name == "result.zip"); confirmed = true; return destination }, isCurrent: { true }, fetch: {
            #expect(confirmed)
            #expect(try Data(contentsOf: destination) == Data("old".utf8))
            try Data("new".utf8).write(to: temporary); return temporary
        })
    #expect(saved)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    do {
        _ = try await MediaSave.perform(reference: MediaReference(source: "/srv/result.zip")!, select: { _ in destination }, isCurrent: { true }, fetch: { throw URLError(.networkConnectionLost) })
        Issue.record("A disconnected download must fail")
    } catch { }
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["chosen.zip"])
}

@Test func mediaRequestUsesActualEndpointAndNeverAuthenticatesExternalOrigin() throws {
    let base = URL(string: "https://server.example.invalid/prefix")!
    let path = "/srv/性能 100% + 'quoted'%20.zip"
    let headers = [CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret")]
    let plan = MediaDownloadPlan(baseURL: base, reference: MediaReference(source: path)!, sessionID: "session + exact", headers: headers)
    let components = try #require(URLComponents(url: plan.request.url!, resolvingAgainstBaseURL: false))
    #expect(components.path == "/prefix/api/media")
    #expect(components.queryItems?.first { $0.name == "path" }?.value == path)
    #expect(components.queryItems?.first { $0.name == "session_id" }?.value == "session + exact")
    #expect(plan.authenticated)
    #expect(plan.request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "fixture-only-secret")
    let external = MediaDownloadPlan(baseURL: base, reference: MediaReference(source: "https://other.example.invalid/file.zip")!, sessionID: "A", headers: headers)
    #expect(!external.authenticated)
    #expect(external.request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    #expect(external.request.httpShouldHandleCookies == false)
}

@Test func mediaWrappedTokensDoNotLeaveMarkdownDelimitersAndPreserveParentheses() {
    let text = "Before [report](MEDIA:/srv/report(1).md) after\n<MEDIA:https://files.example.invalid/a.zip>\nMEDIA:\"/srv/space and 'quote' 100%.zip\" done"
    let parts = MediaTokens.parse(text)
    #expect(parts.compactMap(\.media).map(\.source) == ["/srv/report(1).md", "https://files.example.invalid/a.zip", "/srv/space and 'quote' 100%.zip"])
    #expect(parts.filter { $0.media == nil }.map(\.text).joined() == "Before  after\n\n done")
    let fenced = "  ~~~~text\nMEDIA:/srv/no.zip\n~~~\nMEDIA:/srv/still-no.zip\n~~~~\nMEDIA:/srv/yes.zip"
    #expect(MediaTokens.parse(fenced).compactMap(\.media).map(\.source) == ["/srv/yes.zip"])
    #expect(MediaTokens.parse("``MEDIA:/srv/no.zip``\nMEDIA:/srv/yes.zip").compactMap(\.media).map(\.source) == ["/srv/yes.zip"])
}

@Test func mediaTokensPreserveExactServerPathsAndIgnoreCode() {
    let path = "/srv/reports/性能 100% 'quoted'.zip"
    let text = "Download\nMEDIA:\(path)\n`MEDIA:/srv/not-inline.zip`\n```text\nMEDIA:/srv/not-fenced.zip\n```\n[report](MEDIA:/srv/report.md)\nMEDIA:\"/srv/with spaces.md\"\n<MEDIA:https://files.example.invalid/a%20b.zip>"
    let refs = MediaTokens.parse(text).compactMap(\.media)
    #expect(refs.map(\.source) == [path, "/srv/report.md", "/srv/with spaces.md", "https://files.example.invalid/a%20b.zip"])
    #expect(refs.first?.filename == "性能 100% 'quoted'.zip")
    #expect(MediaReference(source: "javascript:alert(1)") == nil)
    #expect(MediaReference(source: "file:///srv/private.zip") == nil)
    #expect(MediaReference(source: "https://user:password@files.example.invalid/a") == nil)
}
