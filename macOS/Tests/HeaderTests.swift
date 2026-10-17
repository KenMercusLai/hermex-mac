import Foundation
import Testing
@testable import HermexMac

private final class HeaderRequiredProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let allowed = request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-only-id" && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "fixture-only-secret"
        let payload: String
        switch request.url!.path {
        case "/health": payload = #"{"status":"ok"}"#
        case "/api/auth/status": payload = #"{"auth_enabled":false,"logged_in":true}"#
        case "/api/auth/logout" where request.url!.host == "logout-refused.invalid": payload = #"{"ok":false,"error":"fixture-only-secret"}"#
        default: payload = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: allowed ? 200 : 403, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((allowed ? payload : #"{"error":"Missing fixture headers"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func explicitSignoutForgetsHeadersEvenWhenRemoteLogoutFails() async throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.failed-logout.\(UUID())")
    let address = "https://logout-refused.invalid"
    let url = try ServerAddress.parse(address)
    let storage = ConnectionHeaderVault(vault: vault)
    defer { try? storage.clear(for: url); try? vault.delete(account: address); try? vault.delete(account: "connections") }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HeaderRequiredProtocol.self]
    let store = MacStore(sessionFactory: { URLSession(configuration: config) }, vault: vault)
    await store.connect(address: address, password: "", remember: false, customHeaders: [CustomHeader(name: ConnectionHeaders.clientID, value: "fixture-only-id"), CustomHeader(name: ConnectionHeaders.clientSecret, value: "fixture-only-secret")])
    #expect(store.connected)
    try vault.save(Data("fixture-only-password".utf8), account: address)
    await store.logout()
    #expect(!store.connected)
    #expect(try storage.load(for: url).isEmpty)
    #expect(try vault.read(account: address) == nil)
    #expect(store.error?.contains("fixture-only-secret") == false)
}

@Test @MainActor func storedConnectionHeadersReachHealthBeforeAuthentication() async throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.headers-test.\(UUID())")
    let address = "https://fixture.invalid"
    let account = "connection-headers|" + address
    defer { try? vault.delete(account: account); try? vault.delete(account: "connections") }
    let headers = [CustomHeader(name: "CF-Access-Client-Id", value: "fixture-only-id"), CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret")]
    try vault.save(JSONEncoder().encode(headers), account: account)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HeaderRequiredProtocol.self]
    let store = MacStore(sessionFactory: { URLSession(configuration: config) }, vault: vault)
    await store.connect(address: address, password: "", remember: false)
    #expect(store.connected)
    await store.logout()
    #expect(!store.connected)
    #expect(try vault.read(account: account) == nil)
}
