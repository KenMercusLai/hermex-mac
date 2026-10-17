import Testing
import Foundation
@testable import HermexMac

private final class ConnectProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let payload: String
        switch path {
        case "/health": payload = #"{"status":"ok"}"#
        case "/api/auth/status": payload = #"{"auth_enabled":false,"logged_in":true}"#
        case "/api/sessions": payload = #"{"sessions":[{"session_id":"one","title":"First"}]}"#
        case "/api/session/new": payload = #"{"session":{"session_id":"new","title":"Untitled","messages":[]}}"#
        case "/api/session": payload = #"{"session":{"session_id":"one","title":"First","messages":[{"role":"assistant","content":"History"}]}}"#
        default: payload = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test @MainActor func connectingLoadsSessionsAndSelectingLoadsHistory() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ConnectProtocol.self]
    let store = MacStore(persistence: false, sessionFactory: { URLSession(configuration: config) })
    await store.connect(address: "http://fixture.invalid", password: "", remember: false)
    #expect(store.connected)
    #expect(store.sessions.count == 1)
    await store.selectSession("one")
    #expect(store.detail?.sessionId == "one")
    #expect(store.messages.first?.content == "History")
    store.panel = "Memory"
    await store.selectSession("one")
    #expect(store.panel == "Chat")
    store.draft = "Unsent draft"
    await store.newSession()
    #expect(store.detail?.sessionId == "new")
    #expect(store.messages.isEmpty)
    await store.selectSession("one")
    #expect(store.draft == "Unsent draft")
    store.disconnect()
    #expect(!store.connected)
    #expect(store.messages.isEmpty)
    #expect(store.sessions.isEmpty)
    await store.connect(address: "http://second-fixture.invalid", password: "", remember: false)
    await store.selectSession("one")
    #expect(store.draft.isEmpty)
    store.disconnect()
    await store.connect(address: "http://fixture.invalid", password: "", remember: false)
    await store.selectSession("one")
    #expect(store.draft == "Unsent draft")
    store.disconnect()
}

@Test func connectionRegistryIsKeychainBacked() throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.registry-test.\(UUID())")
    defer { try? vault.delete(account: "connections") }
    let registry = ConnectionRegistry(vault: vault)
    try registry.save(servers: [SavedServer(address: "https://fixture.invalid", label: "Fixture")], last: "https://fixture.invalid")
    #expect(try vault.read(account: "connections") != nil)
    let loaded = try registry.load()
    #expect(loaded?.last == "https://fixture.invalid")
    #expect(loaded?.servers.first?.label == "Fixture")
}
