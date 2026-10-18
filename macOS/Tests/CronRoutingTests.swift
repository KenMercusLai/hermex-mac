import Foundation
import Testing
import AppKit
import SwiftUI
import Vision
@testable import HermexMac

private func cronWorker(_ id: String, parent: String) -> SessionSummary {
    SessionSummary(sessionId: id, title: "Worker", rawSource: "subagent", parentSessionId: parent)
}

@Test @MainActor func missingCronParentWorkerLeavesConversationsWithoutJobsAPI() {
    let store = MacStore(persistence: false)
    store.sessions = [SessionSummary(sessionId: "interactive"),
                      cronWorker("worker", parent: "cron_job6728_20260803_100000")]
    #expect(store.sidebarRows.map(\.id) == ["interactive"])
    #expect(store.sessions.map(\.id) == ["interactive", "worker"])
}

private func cronJob(_ wire: String) throws -> CronJob {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(CronJob.self, from: Data(wire.utf8))
}

@Test func exactRealTaskOwnsMissingParentWorkersAndNestedDescendants() throws {
    let job = try cronJob(#"{"id":"job6728","name":"Not the ID"}"#)
    let worker = cronWorker("worker", parent: "cron_job6728_20260803_100000")
    let leaf = cronWorker("leaf", parent: "worker")
    let projection = CronSessionRouting(sessions: [leaf, worker])
    #expect(projection.workers(for: job).map(\.id) == ["leaf", "worker"])
    #expect(projection.conversations.isEmpty)
    let hierarchy = SessionHierarchy(sessions: projection.workers(for: job))
    #expect(hierarchy.rows(expanded: ["worker"]).map(\.id) == ["worker", "leaf"])
}

private final class CronRoutingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: String
        switch request.url!.path {
        case "/health": payload = #"{"status":"ok"}"#
        case "/api/auth/status": payload = #"{"auth_enabled":false,"logged_in":true}"#
        case "/api/sessions": payload = #"{"sessions":[{"session_id":"middle","title":"Cron Delegate","raw_source":"subagent","parent_session_id":"cron_job6728_20260803_100000","read_only":true},{"session_id":"leaf","title":"Nested Delegate","raw_source":"subagent","parent_session_id":"middle","read_only":true},{"session_id":"interactive"}]}"#
        case "/api/sessions/search": payload = #"{"sessions":[{"session_id":"leaf","title":"Nested Delegate","raw_source":"subagent","parent_session_id":"middle","read_only":true},{"session_id":"match","title":"Current match"}]}"#
        case "/api/crons": payload = #"{"jobs":[{"id":"job6728","name":"Backup"}]}"#
        case "/api/session": payload = #"{"session":{"session_id":"leaf","read_only":true,"messages":[{"role":"assistant","content":"Cron worker history"}]}}"#
        default: payload = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private func cronStore() async -> MacStore {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CronRoutingProtocol.self]
    let store = MacStore(persistence: false, sessionFactory: { URLSession(configuration: config) })
    await store.connect(address: "https://cron-routing.invalid", password: "", remember: false)
    return store
}

@Test @MainActor func searchUsesFullRelationshipSnapshotButOutputsOnlyCurrentMatches() async throws {
    let store = await cronStore()
    defer { store.disconnect() }
    store.search = "leaf"
    try await store.reloadSessions()
    #expect(store.sidebarRows.map(\.id) == ["match"])
    // Current authoritative matches must precede cached relationships, including
    // a changed parent; the cache is not permission to resurrect an old link.
    store.sessions = [cronWorker("leaf", parent: "ordinary-missing")]
    #expect(store.sidebarRows.map(\.id) == ["leaf"])
}

@Test @MainActor func tasksRefreshUsesFullCatalogAndDisclosureDoesNotSelectWorker() async throws {
    let store = await cronStore()
    defer { store.disconnect() }
    store.search = "leaf"
    try await store.reloadSessions()
    await store.reloadTasks()
    let job = try #require(store.taskJobs.first)
    #expect(job.jobId == "job6728")
    #expect(store.taskWorkerCount(for: job) == 2)
    #expect(store.taskRows(for: job).isEmpty)
    store.toggleTaskDisclosure(job.id)
    #expect(store.selectedID == nil)
    #expect(store.taskRows(for: job).map(\.id) == ["middle"])
    store.toggleTaskWorkerDisclosure("middle")
    #expect(store.taskRows(for: job).map(\.id) == ["middle", "leaf"])
    #expect(store.sidebarRows.map(\.id) == ["match"])
    await store.selectSession("leaf")
    #expect(store.selectedID == "leaf")
    #expect(store.detail?.readOnly == true)
    #expect(store.messages.first?.content == "Cron worker history")
    store.disconnect()
    #expect(store.taskJobs.isEmpty)
    #expect(store.fullSessions.isEmpty)
    #expect(store.expandedTaskIDs.isEmpty)
}

@Test @MainActor func tasksPanelRendersExpandedWorkersOffscreen() async throws {
    _ = NSApplication.shared
    let store = await cronStore()
    defer { store.disconnect() }
    await store.reloadTasks()
    store.toggleTaskDisclosure("job6728")
    store.toggleTaskWorkerDisclosure("middle")
    let host = NSHostingView(rootView: ServerPanelView(store: store, kind: "Tasks")
        .frame(width: 1000, height: 700).background(Color.white).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch/cron-tasks-offscreen.png")
    try png.write(to: destination)
    // In-process NSHostingView has no AX tree without an interactive application.
    // Assert actual native pixels instead, not a source-string/UI mock check.
    let recognize = VNRecognizeTextRequest()
    try VNImageRequestHandler(data: png).perform([recognize])
    let text = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    #expect(text.contains("Backup"))
    #expect(text.contains("Cron Delegate"))
    #expect(text.contains("Nested Delegate"))
    print("CRON TASKS OFFSCREEN: \(destination.path)")
}

@Test @MainActor func nestedCronDescendantsHiddenEvenWhenRunAndJobsAreMissing() {
    let store = MacStore(persistence: false)
    store.sessions = [cronWorker("leaf", parent: "middle"),
                      cronWorker("middle", parent: "cron_deleted_job_20261018_090000"),
                      cronWorker("ordinary-orphan", parent: "absent")]
    #expect(store.sidebarRows.map(\.id) == ["ordinary-orphan"])
}

@Test func taskRoutingRejectsReportedProfileMismatchIncludingAncestors() throws {
    let job = try cronJob(#"{"id":"backup_full","profile":"default"}"#)
    let root = SessionSummary(sessionId: "cron_backup_full_20261018_090000", profile: "other", rawSource: "cron")
    let worker = cronWorker("worker", parent: root.id)
    let leaf = SessionSummary(sessionId: "leaf", profile: "default", rawSource: "subagent", parentSessionId: worker.id)
    let projection = CronSessionRouting(sessions: [root, worker, leaf])
    #expect(projection.workers(for: job).isEmpty)
    #expect(projection.conversations.map(\.id) == [root.id])
}

@Test func cronRunParserIsAnchoredAndPreservesOpaqueJobIDs() throws {
    #expect(CronSessionRouting.jobID(fromRunID: "cron_backup_full_20261018_090000") == "backup_full")
    #expect(CronSessionRouting.jobID(fromRunID: "cron_ BACKUP _20261018_090000") == " BACKUP ")
    for malformed in ["cron__20261018_090000", " cron_backup_20261018_090000", "CRON_backup_20261018_090000",
                      "cron_backup_20261018_090000\n", "cron_backup_20261018_090000_suffix", "cron_backup_20261018_09000",
                      "cron_backup_2026101_090000", "cron_backup_abcdefgh_090000"] {
        #expect(CronSessionRouting.jobID(fromRunID: malformed) == nil)
    }
    let projection = CronSessionRouting(sessions: [cronWorker("w", parent: "cron_backup_full_20261018_090000")])
    for wire in [#"{"id":"backup"}"#, #"{"name":"backup_full"}"#, #"{"id":"BACKUP_full"}"#, #"{"id":" backup_full "}"#] {
        #expect(projection.workers(for: try cronJob(wire)).isEmpty)
    }
}

@Test func reportedCronAncestorWithMalformedIDHidesButCannotClaimTask() throws {
    let root = SessionSummary(sessionId: "cron_backup_20261018_090000_suffix", rawSource: "cron")
    let worker = cronWorker("worker", parent: root.id)
    let leaf = cronWorker("leaf", parent: worker.id)
    let orphan = cronWorker("unproven", parent: "cron_backup_20261018_090000_suffix_missing")
    let projection = CronSessionRouting(sessions: [root, worker, leaf, orphan])
    #expect(projection.conversations.map(\.id) == [root.id, "unproven"])
    #expect(projection.workers(for: try cronJob(#"{"id":"backup"}"#)).isEmpty)
}

@Test func cronRootAndNonDelegationLinksRemainInConversationsWithStableDuplicatesAndCycles() {
    let root = SessionSummary(sessionId: "cron_backup_20261018_090000", rawSource: "cron")
    let fork = SessionSummary(sessionId: "fork", rawSource: "subagent", parentSessionId: root.id, relationshipType: "fork")
    let compression = SessionSummary(sessionId: "compression", rawSource: "subagent", parentSessionId: root.id, relationshipType: "compression")
    let ordinary = cronWorker("orphan", parent: "missing")
    let a = cronWorker("a", parent: "b"), b = cronWorker("b", parent: "a")
    let worker = cronWorker("w", parent: root.id)
    let duplicate = SessionSummary(sessionId: "w", title: "ignored")
    let projection = CronSessionRouting(sessions: [root, worker, duplicate, fork, compression, ordinary, a, b])
    #expect(projection.conversations.map(\.id) == [root.id, "fork", "compression", "orphan", "a", "b"])
}

