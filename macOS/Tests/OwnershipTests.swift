import Foundation
import Testing
@testable import HermexMac

// Explicit URLProtocol gates: tests wait for request arrival, change ownership,
// then release that exact response. No timing sleeps or live servers/secrets.
private final class DelayedProtocol: URLProtocol {
    static let lock = NSLock()
    static var fixtures: [String: DelayedFixture] = [:]
    private let deliveryLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixtures[request.url!.host!]; Self.lock.unlock()
        fixture!.receive(self)
    }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }
    func finish(_ payload: String) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DelayedFixture {
    struct Request {
        let path: String
        let query: [String: String]
        let body: [String: Any]
    }
    let address = "https://\(UUID().uuidString.lowercased()).invalid"
    private let lock = NSLock()
    private var requests: [Request] = []
    private var gate: ((Request) -> Bool)?
    private var held: (DelayedProtocol, String)?
    private var waiter: CheckedContinuation<Void, Never>?
    private var sessions: [URLSession] = []
    private var responder: ((Request, Int) -> String)?
    var response: ((Request, Int) -> String)? {
        get { lock.lock(); defer { lock.unlock() }; return responder }
        set { lock.lock(); defer { lock.unlock() }; responder = newValue }
    }
    init() {
        DelayedProtocol.lock.lock(); DelayedProtocol.fixtures[URL(string: address)!.host!] = self; DelayedProtocol.lock.unlock()
    }
    func close() {
        release()
        sessions.forEach { $0.finishTasksAndInvalidate() }
        DelayedProtocol.lock.lock(); DelayedProtocol.fixtures.removeValue(forKey: URL(string: address)!.host!); DelayedProtocol.lock.unlock()
    }
    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedProtocol.self]
        let session = URLSession(configuration: config)
        sessions.append(session)
        return session
    }
    func hold(_ path: String, session: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        gate = { $0.path == path && (session == nil || $0.query["session_id"] == session) }
    }
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if held != nil { continuation.resume() } else { waiter = continuation }
        }
    }
    func release() {
        lock.lock(); let value = held; held = nil; lock.unlock()
        if let (proto, payload) = value { proto.finish(payload) }
    }
    func seen(_ path: String) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.path == path }
    }
    func receive(_ proto: DelayedProtocol) {
        var data = proto.request.httpBody ?? Data()
        if let stream = proto.request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
        }
        let request = Request(path: proto.request.url!.path,
            query: Dictionary(uniqueKeysWithValues: (URLComponents(url: proto.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
            body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        lock.lock()
        requests.append(request)
        let count = requests.filter { $0.path == request.path }.count
        let payload = responder?(request, count) ?? Self.payload(request)
        if gate?(request) == true {
            gate = nil; held = (proto, payload)
            let notify = waiter; waiter = nil; lock.unlock(); notify?.resume()
        } else { lock.unlock(); proto.finish(payload) }
    }
    static func session(_ id: String) -> String {
        #"{"session":{"session_id":"\#(id)","workspace":"/\#(id)","model":"model-\#(id)","messages":[{"role":"assistant","content":"history-\#(id)"}]}}"#
    }
    static func payload(_ request: Request) -> String {
        switch request.path {
        case "/health": return #"{"status":"ok"}"#
        case "/api/auth/status": return #"{"auth_enabled":false,"logged_in":true}"#
        case "/api/session": return session(request.query["session_id"] ?? "missing")
        case "/api/session/update": return session(request.body["session_id"] as? String ?? "missing")
        case "/api/session/new": return session("new")
        case "/api/session/status": return #"{"active_stream_id":"stream-A"}"#
        case "/api/chat/stream/status": return #"{"active":false,"replay_available":false}"#
        case "/api/chat/start": return #"{"error":"fixture records send without starting a run"}"#
        default: return #"{"ok":true}"#
        }
    }
}

@Test @MainActor func delayedSelectionFailuresDoNotOverwriteCurrentError() async throws {
    for operation in ["older", "upload", "send", "new"] {
        let fixture = DelayedFixture(); defer { fixture.close() }
        let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
        await store.connect(address: fixture.address, password: "", remember: false)
        await store.selectSession("A")
        let path = operation == "older" ? "/api/session" : operation == "upload" ? "/api/upload" : operation == "send" ? "/api/chat/start" : "/api/session/new"
        fixture.response = { request, _ in request.path == path ? "invalid fixture JSON" : DelayedFixture.payload(request) }
        if operation == "older" {
            store.detail = try JSONDecoder().decode(SessionDetail.self, from: Data(#"{"sessionId":"A","messagesOffset":100}"#.utf8))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hermex-ownership-\(UUID()).txt")
        try Data("fixture-only".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        store.draft = "draft-A"
        fixture.hold(path)
        let task = Task {
            switch operation {
            case "older": await store.loadOlder()
            case "upload": await store.upload([file])
            case "send": await store.send()
            default: await store.newSession()
            }
        }
        await fixture.waitUntilHeld()
        // Restore normal history before selecting B; held A payload is frozen.
        fixture.response = nil
        await store.selectSession("B")
        store.error = "current-B-error"
        fixture.release(); await task.value
        #expect(store.error == "current-B-error")
        #expect(store.selectedID == "B")
        store.disconnect()
    }
}

@Test @MainActor func delayedSendCannotReleaseAnotherConnectionsBusyState() async {
    let first = DelayedFixture(), second = DelayedFixture()
    defer { first.close(); second.close() }
    let store = MacStore(persistence: false, sessionFactory: first.makeSession)
    await store.connect(address: first.address, password: "", remember: false)
    await store.selectSession("A")
    store.api = APIClient(baseURL: URL(string: first.address)!, session: first.makeSession(), customHeaderProvider: { [] })
    store.draft = "draft-A"
    first.hold("/api/chat/start")
    let send = Task { await store.send() }
    await first.waitUntilHeld()
    store.disconnect()
    second.hold("/health")
    let connect = Task { await store.connect(address: second.address, password: "", remember: false) }
    await second.waitUntilHeld()
    first.release(); await send.value
    #expect(store.busy == true)
    #expect(store.error == nil)
    second.release(); await connect.value
    #expect(store.connected == true)
    store.disconnect()
}

@Test @MainActor func delayedRefreshFailureCannotOverwriteAnotherConnection() async {
    let first = DelayedFixture(), second = DelayedFixture()
    defer { first.close(); second.close() }
    let store = MacStore(persistence: false, sessionFactory: first.makeSession)
    await store.connect(address: first.address, password: "", remember: false)
    store.api = APIClient(baseURL: URL(string: first.address)!, session: first.makeSession(), customHeaderProvider: { [] })
    first.response = { request, _ in request.path == "/api/sessions" ? "invalid fixture JSON" : DelayedFixture.payload(request) }
    first.hold("/api/sessions")
    let task = Task { await store.refresh() }
    await first.waitUntilHeld()
    store.disconnect()
    await store.connect(address: second.address, password: "", remember: false)
    store.error = "current-B-error"
    first.release(); await task.value
    #expect(store.error == "current-B-error")
    store.disconnect()
}

@Test @MainActor func delayedInputResponseCannotClearAnotherSelectionsRequests() async {
    for path in ["/api/approval/respond", "/api/clarify/respond"] {
        let fixture = DelayedFixture(); defer { fixture.close() }
        let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
        await store.connect(address: fixture.address, password: "", remember: false)
        await store.selectSession("A")
        store.run.approval = PendingApproval(approvalId: "approval-A")
        store.run.clarification = PendingClarification(clarifyId: "clarify-A")
        fixture.hold(path)
        let task = Task {
            if path == "/api/approval/respond" { await store.approve(.once) }
            else { await store.clarify("fixture answer") }
        }
        await fixture.waitUntilHeld()
        await store.selectSession("B")
        store.run.approval = PendingApproval(approvalId: "approval-B")
        store.run.clarification = PendingClarification(clarifyId: "clarify-B")
        fixture.release(); await task.value
        #expect(store.run.approval?.approvalId == "approval-B")
        #expect(store.run.clarification?.clarifyId == "clarify-B")
        #expect(fixture.seen("/api/approval/pending").isEmpty)
        #expect(fixture.seen("/api/clarify/pending").isEmpty)
        store.disconnect()
    }
}

@Test @MainActor func delayedPendingProbeStopsAfterSelectionChanges() async {
    let fixture = DelayedFixture(); defer { fixture.close() }
    let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
    await store.connect(address: fixture.address, password: "", remember: false)
    await store.selectSession("A")
    fixture.hold("/api/approval/pending")
    let task = Task { await store.checkPending() }
    await fixture.waitUntilHeld()
    await store.selectSession("B")
    fixture.release(); await task.value
    #expect(fixture.seen("/api/clarify/pending").isEmpty)
    store.disconnect()
}

@Test @MainActor func delayedLogoutCannotForgetOrDisconnectAnotherServer() async throws {
    for switchConnection in [false, true] {
        let first = DelayedFixture(), second = DelayedFixture()
        defer { first.close(); second.close() }
        let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.logout-test.\(UUID())")
        defer { for key in [first.address, second.address, "connections"] { try? vault.delete(account: key) } }
        try vault.save(Data("A-only".utf8), account: first.address)
        try vault.save(Data("B-only".utf8), account: second.address)
        let store = MacStore(sessionFactory: first.makeSession, vault: vault)
        await store.connect(address: first.address, password: "", remember: false)
        // Separate test transport forces delivery after disconnect; cancellation
        // of the store's transport cannot conceal a missing ownership check.
        store.api = APIClient(baseURL: URL(string: first.address)!, session: first.makeSession(), customHeaderProvider: { [] })
        first.hold("/api/auth/logout")
        let task = Task { await store.logout() }
        await first.waitUntilHeld()
        if switchConnection {
            store.disconnect()
            await store.connect(address: second.address, password: "", remember: false)
            await store.selectSession("B")
        } else { store.address = second.address }
        first.release(); await task.value
        #expect(try vault.read(account: second.address) == Data("B-only".utf8))
        if switchConnection {
            #expect(store.connected == true)
            #expect(store.selectedID == "B")
            #expect(store.error == nil)
        } else {
            #expect(try vault.read(account: first.address) == nil)
            #expect(store.connected == false)
        }
        store.disconnect()
    }
}

@Test @MainActor func delayedCatalogCannotOverwriteAnotherConnection() async {
    for path in ["/api/providers", "/api/profiles", "/api/workspaces"] {
        let first = DelayedFixture(), second = DelayedFixture()
        defer { first.close(); second.close() }
        for (fixture, tag) in [(first, "A"), (second, "B")] {
            fixture.response = { request, _ in
                switch request.path {
                case "/api/providers": return #"{"providers":[{"id":"\#(tag)"}]}"#
                case "/api/profiles": return #"{"profiles":[{"name":"\#(tag)"}],"active":"\#(tag)"}"#
                case "/api/workspaces": return #"{"workspaces":["/\#(tag)"],"last":"/\#(tag)"}"#
                default: return DelayedFixture.payload(request)
                }
            }
        }
        let store = MacStore(persistence: false, sessionFactory: first.makeSession)
        await store.connect(address: first.address, password: "", remember: false)
        store.api = APIClient(baseURL: URL(string: first.address)!, session: first.makeSession(), customHeaderProvider: { [] })
        first.hold(path)
        let task = Task { await store.loadCatalog() }
        await first.waitUntilHeld()
        store.disconnect()
        await store.connect(address: second.address, password: "", remember: false)
        first.release(); await task.value
        #expect(store.providers.first?.id == "B")
        #expect(store.profiles.first?.name == "B")
        #expect(store.workspaces.first?.path == "/B")
        #expect(store.profile == "B")
        #expect(store.workspace == "/B")
        #expect(store.error == nil)
        store.disconnect()
    }
}

@Test @MainActor func delayedNewSessionCannotReplaceLaterSelection() async {
    await verifyDelayedSelection(path: "/api/session/new") { await $0.newSession() }
}
@Test @MainActor func delayedStopCannotClearAnotherRun() async {
    await verifyStopOwnership(path: "/api/chat/cancel")
}
@Test @MainActor func delayedStopHistoryCannotInstallAnotherSession() async {
    await verifyStopOwnership(path: "/api/session")
}
@MainActor private func verifyStopOwnership(path: String) async {
    let fixture = DelayedFixture(); defer { fixture.close() }
    let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
    await store.connect(address: fixture.address, password: "", remember: false)
    await store.selectSession("A")
    store.streamID = "stream-A"; store.streaming = true
    fixture.hold(path, session: path == "/api/session" ? "A" : nil)
    let task = Task { await store.stop() }
    await fixture.waitUntilHeld()
    await store.selectSession("B")
    store.streamID = "stream-B"; store.streaming = true; store.run.text = "projection-B"
    fixture.release(); await task.value
    #expect(store.selectedID == "B")
    #expect(store.messages.first?.content == "history-B")
    #expect(store.streamID == "stream-B")
    #expect(store.streaming == true)
    #expect(store.run.text == "projection-B")
    #expect(fixture.seen("/api/chat/cancel").count == 1)
    #expect(fixture.seen("/api/chat/cancel").first?.query["stream_id"] == "stream-A")
    store.disconnect()
}

@Test @MainActor func delayedReattachStatusCannotAttachToAnotherSelection() async {
    await verifyReattachOwnership(stage: "session-status")
}
@Test @MainActor func delayedReattachStreamStatusCannotClearAnotherRun() async {
    await verifyReattachOwnership(stage: "stream-status")
}
@Test @MainActor func delayedReattachHistoryCannotInstallAnotherSession() async {
    await verifyReattachOwnership(stage: "history")
}
@MainActor private func verifyReattachOwnership(stage: String) async {
    let fixture = DelayedFixture(); defer { fixture.close() }
    let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
    await store.connect(address: fixture.address, password: "", remember: false)
    await store.selectSession("A")
    if stage != "session-status" { store.streamID = "stream-A" }
    fixture.hold(stage == "session-status" ? "/api/session/status" : stage == "stream-status" ? "/api/chat/stream/status" : "/api/session", session: stage == "history" ? "A" : nil)
    let task = Task { await store.reattach() }
    await fixture.waitUntilHeld()
    await store.selectSession("B")
    store.draft = "draft-B"
    store.streamID = "stream-B"; store.streaming = true; store.run.text = "projection-B"
    fixture.release(); await task.value
    #expect(store.selectedID == "B")
    #expect(store.messages.first?.content == "history-B")
    #expect(store.draft == "draft-B")
    #expect(store.streamID == "stream-B")
    #expect(store.streaming == true)
    #expect(store.run.text == "projection-B")
    #expect(fixture.seen("/api/chat/stream").isEmpty)
    #expect(fixture.seen("/api/approval/pending").isEmpty)
    await store.stop()
    #expect(fixture.seen("/api/chat/cancel").last?.query["stream_id"] == "stream-B")
    store.disconnect()
}

@Test @MainActor func delayedSessionSettingsCannotRetargetAnotherDraft() async {
    await verifyDelayedSelection(path: "/api/session/update") { await $0.saveSessionControls() }
}

@Test @MainActor func delayedMutationReadbackCannotRetargetAnotherDraft() async {
    await verifyDelayedSelection(path: "/api/session") { await $0.mutate("A", action: .rename("renamed")) }
}

@MainActor private func verifyDelayedSelection(path: String, action: @escaping @MainActor (MacStore) async -> Void) async {
    let fixture = DelayedFixture(); defer { fixture.close() }
    let store = MacStore(persistence: false, sessionFactory: fixture.makeSession)
    await store.connect(address: fixture.address, password: "", remember: false)
    await store.selectSession("A")
    store.draft = "draft-A"
    fixture.hold(path, session: path == "/api/session" ? "A" : nil)
    let task = Task { await action(store) }
    await fixture.waitUntilHeld()
    await store.selectSession("B")
    let attachment = PendingAttachment(name: "B.txt", path: "/uploads/B.txt", mime: "text/plain", isImage: false)
    store.draft = "draft-B"; store.attachments = [attachment]
    fixture.release(); await task.value
    #expect(store.selectedID == "B")
    #expect(store.detail?.sessionId == "B")
    #expect(store.messages.first?.content == "history-B")
    #expect(store.workspace == "/B")
    #expect(store.model == "model-B")
    #expect(store.draft == "draft-B")
    #expect(store.attachments == [attachment])
    await store.send()
    #expect(fixture.seen("/api/chat/start").last?.body["session_id"] as? String == "B")
    #expect((fixture.seen("/api/chat/start").last?.body["message"] as? String)?.contains("draft-B") == true)
    store.disconnect()
}

@Test @MainActor func disconnectedAuthenticationCannotPublishOrBlockNextConnection() async {
    let first = DelayedFixture(), second = DelayedFixture()
    defer { first.close(); second.close() }
    let store = MacStore(persistence: false, sessionFactory: first.makeSession)
    first.hold("/api/auth/status")
    let task = Task { await store.connect(address: first.address, password: "", remember: false) }
    await first.waitUntilHeld()
    store.disconnect()
    await store.connect(address: second.address, password: "", remember: false)
    first.release(); await task.value
    #expect(store.connected)
    #expect(store.address == second.address)
    #expect(store.error == nil)
    #expect(!store.busy)
    store.disconnect()
}

@Test @MainActor func connectionCredentialsStayBoundToValidatedAddress() async throws {
    for remember in [true, false] {
        let fixture = DelayedFixture(); defer { fixture.close() }
        fixture.response = { request, count in
            if request.path == "/api/auth/status" { return count == 1 ? #"{"auth_enabled":true,"logged_in":false}"# : #"{"auth_enabled":true,"logged_in":true}"# }
            return DelayedFixture.payload(request)
        }
        let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.ownership-test.\(UUID())")
        let other = "https://other.invalid"
        defer { for key in [fixture.address, other, "connections"] { try? vault.delete(account: key) } }
        try vault.save(Data("fixture-A-only".utf8), account: fixture.address)
        try vault.save(Data("fixture-B-only".utf8), account: other)
        let store = MacStore(sessionFactory: fixture.makeSession, vault: vault)
        fixture.hold("/api/auth/status")
        let task = Task { await store.connect(address: fixture.address, password: "", remember: remember) }
        await fixture.waitUntilHeld()
        store.address = other
        fixture.release(); await task.value
        #expect(store.connected)
        #expect(fixture.seen("/api/auth/login").first?.body["password"] as? String == "fixture-A-only")
        #expect(try vault.read(account: other) == Data("fixture-B-only".utf8))
        #expect(try vault.read(account: fixture.address) == (remember ? Data("fixture-A-only".utf8) : nil))
        #expect(try ConnectionRegistry(vault: vault).load()?.last == fixture.address)
        #expect(store.servers.map(\.address) == [fixture.address])
        store.disconnect()
    }
}
