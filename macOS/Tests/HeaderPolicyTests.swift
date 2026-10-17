import Foundation
import Testing
@testable import HermexMac

@Test func headerValidationRejectsInjectionAndProtectsTransport() throws {
    #expect(try ConnectionHeaders.validated(ConnectionHeaders.placeholders).isEmpty)
    for name in ["Bad Name", "Bad:Name", "", "Bad\rName", "é"] {
        #expect(throws: (any Error).self) { try ConnectionHeaders.validated([CustomHeader(name: name, value: "fixture-only")]) }
    }
    for value in ["fixture\r\nx: injected", "fixture\0secret", "fixture\tsecret", "\n"] {
        #expect(throws: (any Error).self) { try ConnectionHeaders.validated([CustomHeader(name: "X-Test", value: value)]) }
    }
    for name in ["Host", "COOKIE", "Content-Length", "Transfer-Encoding", "Proxy-Authorization"] {
        #expect(throws: (any Error).self) { try ConnectionHeaders.validated([CustomHeader(name: name, value: "fixture-only")]) }
    }
    #expect(throws: (any Error).self) { try ConnectionHeaders.validated([CustomHeader(name: ConnectionHeaders.clientID, value: "fixture-only")]) }
    let rows = try ConnectionHeaders.validated([CustomHeader(name: " x-test ", value: " first "), CustomHeader(name: "X-Test", value: "last"), CustomHeader(name: "Accept", value: "custom")])
    #expect(rows.count == 2)
    #expect(rows[0].value == "last")
    var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
    rows.apply(to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test @MainActor func headerDraftsNeverMigrateWhenAddressIsTypedPastedOrSelected() throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.header-drafts.\(UUID())")
    let a = try ServerAddress.parse("https://a.invalid")
    let b = try ServerAddress.parse("https://b.invalid")
    let storage = ConnectionHeaderVault(vault: vault)
    defer { try? storage.clear(for: a); try? storage.clear(for: b); try? vault.delete(account: "connections") }
    try storage.save([CustomHeader(name: "X-Token", value: "fixture-only-a")], for: a)
    try storage.save([CustomHeader(name: "X-Token", value: "fixture-only-b")], for: b)
    let store = MacStore(vault: vault)
    store.address = a.absoluteString
    #expect(store.connectionHeaders.first?.value == "fixture-only-a")
    store.connectionHeaders[0].value = "fixture-only-draft-a"
    for raw in ["https://a.invali", "https:", "arbitrary invalid text", b.absoluteString] {
        store.address = raw
        #expect(!store.connectionHeaders.contains { $0.value.contains("draft-a") })
    }
    #expect(store.connectionHeaders.first?.value == "fixture-only-b")
    store.address = a.absoluteString
    #expect(store.connectionHeaders.first?.value == "fixture-only-draft-a")
    store.address = b.absoluteString
    store.clearConnectionHeaders()
    #expect(try storage.load(for: b).isEmpty)
    store.address = a.absoluteString
    #expect(store.connectionHeaders.first?.value == "fixture-only-draft-a")
    let relaunched = MacStore(vault: vault)
    relaunched.address = a.absoluteString
    #expect(relaunched.connectionHeaders.first?.value == "fixture-only-a")
    relaunched.address = b.absoluteString
    #expect(relaunched.connectionHeaders.allSatisfy { $0.value.isEmpty })
    #expect(try vault.read(account: a.absoluteString) == nil) // independent from password
}

@Test func cloudflareDenialIsSpecificAndNeverEchoesResponseSecrets() {
    let url = URL(string: "https://fixture.invalid/health")!
    let cf = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Server":"cloudflare", "Content-Type":"text/html"])!
    let text = ConnectionFailure.httpMessage(response: cf, data: Data("<html>fixture-only-sensitive</html>".utf8))
    #expect(text?.contains("Service Token") == true)
    #expect(text?.contains("WebUI password") == true)
    #expect(text?.contains("fixture-only-sensitive") == false)
    let origin = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Server":"cloudflare", "Content-Type":"application/json"])!
    #expect(ConnectionFailure.httpMessage(response: origin, data: Data(#"{"error":"permission denied"}"#.utf8))?.contains("Cloudflare") == false)
    let login = HTTPURLResponse(url: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/html"])!
    #expect(ConnectionFailure.httpMessage(response: login, data: Data())?.contains("Service Auth") == true)
}
