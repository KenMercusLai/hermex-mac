import Foundation
import CryptoKit

private func mediaFileHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

import Testing
@testable import HermexMac

private final class MediaWireFixture {
    let process = Process()
    let input = Pipe()
    let first: URL, second: URL
    let sha256: String
    let size: Int
    init() throws {
        let output = Pipe()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("media_fixture.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.environment = Dictionary(uniqueKeysWithValues: ["HOME", "PATH", "TMPDIR"].compactMap { key in ProcessInfo.processInfo.environment[key].map { (key, $0) } })
        process.environment?["TMPDIR"] = MediaTestSupport.scratch.path
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.availableData
        struct Info: Decodable { let first: URL; let second: URL; let sha256: String; let size: Int }
        let info = try JSONDecoder().decode(Info.self, from: data)
        first = info.first; second = info.second; sha256 = info.sha256; size = info.size
    }
    func close() { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
}

@Test @MainActor func mediaStoreRealWireCancelIsRequestFreeThenConfirmedSaveUsesAuthenticatedClient() async throws {
    let fixture = try MediaWireFixture(); defer { fixture.close() }
    let store = MacStore(persistence: false)
    store.address = fixture.first.absoluteString
    store.connectionHeaders = [CustomHeader(name: "CF-Access-Client-Id", value: "fixture-only-id"), CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret")]
    await store.connect(address: fixture.first.absoluteString, password: "fixture-only-password", remember: false)
    defer { store.disconnect() }
    #expect(store.connected)
    let connectedClient = try #require(store.api)
    let publicConfiguration = await connectedClient.publicMediaSession.configuration
    #expect(publicConfiguration.httpCookieStorage == nil)
    #expect(publicConfiguration.urlCredentialStorage == nil)
    #expect(publicConfiguration.httpShouldSetCookies == false)
    await store.selectSession("A")
    #expect(store.detail?.sessionId == "A")
    let folder = MediaTestSupport.scratch.appendingPathComponent("media-store-wire-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let chosen = folder.appendingPathComponent("chosen.zip")
    let reference = MediaReference(source: "/srv/result.zip")!
    let probe = URLSession(configuration: .ephemeral)
    defer { probe.invalidateAndCancel() }
    func mediaEvents() async throws -> [[String: Any]] {
        let (data, _) = try await probe.data(from: fixture.first.appendingPathComponent("events"))
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/api/media" }
    }
    await store.saveMedia(reference, select: { _ in nil })
    #expect(try await mediaEvents().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    await store.saveMedia(reference, select: { _ in chosen })
    #expect(store.error == nil)
    #expect(try await mediaEvents().count == 1)
    #expect(try FileManager.default.attributesOfItem(atPath: chosen.path)[.size] as? Int == fixture.size)
    let input = try FileHandle(forReadingFrom: chosen); defer { try? input.close() }
    var hash = SHA256()
    while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk) }
    #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == fixture.sha256)
}

@Test @MainActor func mediaRealLoopbackDownloadHashAuthErrorsAndOrigins() async throws {
    let fixture = try MediaWireFixture(); defer { fixture.close() }
    let config = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: config)
    let publicConfig = URLSessionConfiguration.ephemeral
    publicConfig.httpCookieStorage = nil; publicConfig.httpShouldSetCookies = false; publicConfig.httpCookieAcceptPolicy = .never
    let publicSession = URLSession(configuration: publicConfig)
    defer { session.invalidateAndCancel(); publicSession.invalidateAndCancel() }
    let headers = [CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret")]
    let api = APIClient(baseURL: fixture.first, session: session, publicMediaSession: publicSession, customHeaderProvider: { headers })
    _ = try await api.login(password: "fixture-only-password")
    let folder = MediaTestSupport.scratch.appendingPathComponent("media-wire-output-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("chosen.zip")
    let path = "/srv/性能 100% + 'quoted'%20.zip"
    let reference = MediaReference(source: path)!
    var confirmed = false
    let saved = try await MediaSave.perform(reference: reference, select: { _ in confirmed = true; return destination }, isCurrent: { true }, fetch: {
        #expect(confirmed)
        return try await api.downloadMedia(reference: reference, sessionID: "A + exact", headers: headers)
    })
    #expect(saved)
    let file = try FileHandle(forReadingFrom: destination); defer { try? file.close() }
    var hash = SHA256(), count = 0
    while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk); count += chunk.count }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(digest == fixture.sha256)
    #expect(count == fixture.size)
    #expect(count > 16 * 1024 * 1024)
    for source in ["/srv/401", "/srv/403", "/srv/404", "/srv/disconnect", "/srv/redirect"] {
        do {
            _ = try await MediaSave.perform(reference: MediaReference(source: source)!, select: { _ in destination }, isCurrent: { true }, fetch: {
                try await api.downloadMedia(reference: MediaReference(source: source)!, sessionID: "A", headers: headers)
            })
            Issue.record("Expected rejected download: \(source)")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-only-secret"))
            if case MediaDownloadFailure.status(let code) = error {
                #expect(code == (source == "/srv/redirect" ? 302 : Int(source.suffix(3))))
            } else { #expect(source == "/srv/disconnect") }
        }
        #expect(try mediaFileHash(destination) == fixture.sha256)
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int == fixture.size)
    }
    let redirected = try await api.downloadMedia(reference: MediaReference(source: "/srv/same-redirect")!, sessionID: "A", headers: headers)
    try FileManager.default.removeItem(at: redirected)
    let external = try await api.downloadMedia(reference: MediaReference(source: fixture.second.appendingPathComponent("external").absoluteString)!, sessionID: "A", headers: headers)
    try FileManager.default.removeItem(at: external)
    let (eventsData, _) = try await publicSession.data(from: fixture.first.appendingPathComponent("events"))
    let events = try #require(JSONSerialization.jsonObject(with: eventsData) as? [[String: Any]])
    let firstEvent = try #require(events.first)
    let query = try #require(firstEvent["query"] as? [String: [String]])
    #expect(query["path"] == [path]); #expect(query["session_id"] == ["A + exact"])
    #expect(!events.contains { $0["path"] as? String == "/capture" })
    for event in events {
        let fields = (event["headers"] as? [String: String] ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if event["origin"] as? String == "public" {
            #expect(fields["cf-access-client-secret"] == nil); #expect(fields["cookie"] == nil); #expect(fields["authorization"] == nil)
        } else {
            #expect(fields["cf-access-client-secret"] == "fixture-only-secret")
            #expect(fields["cookie"]?.contains("fixture-only-cookie") == true)
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["chosen.zip"])
    print("MEDIA WIRE PASSED: \(count) bytes SHA256 \(digest); exact query, cookie + CF auth, 401/403/404/disconnect atomic preservation, same-origin redirect, cross-origin redirect blocked, public cookieless download")
}
