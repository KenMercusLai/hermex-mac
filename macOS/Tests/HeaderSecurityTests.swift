import Foundation
import Testing
@testable import HermexMac

@Test func originComparisonIncludesSchemeHostAndEffectivePort() {
    let base = URL(string: "https://EXAMPLE.invalid")!
    #expect(APIClient.isSameOrigin(URL(string: "https://example.invalid:443/path")!, as: base))
    for other in ["http://example.invalid", "https://example.invalid:444", "https://other.invalid"] {
        #expect(!APIClient.isSameOrigin(URL(string: other)!, as: base))
    }
}

@Test func redirectPolicyPreservesSameOriginStripsCaseInsensitiveNamesAndBlocksPasswordPOST() async {
    let base = URL(string: "https://fixture.invalid")!
    let snapshot = [CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret"), CustomHeader(name: "X-Api-Key", value: "fixture-only-key")]
    let delegate = CrossOriginHeaderStripper(baseURL: base, customHeaderProvider: { snapshot })
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: base)
    let response = HTTPURLResponse(url: base, statusCode: 307, httpVersion: nil, headerFields: [:])!
    func redirect(_ url: String, method: String = "GET") async -> URLRequest? {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("fixture-only-secret", forHTTPHeaderField: "cF-aCcEsS-cLiEnT-sEcReT")
        request.setValue("fixture-only-key", forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.httpBody = Data(#"{"password":"fixture-only-password"}"#.utf8) }
        return await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { continuation.resume(returning: $0) }
        }
    }
    let same = await redirect("https://fixture.invalid:443/path")
    #expect(same?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "fixture-only-secret")
    for other in ["https://other.invalid", "http://fixture.invalid", "https://fixture.invalid:444"] {
        let stripped = await redirect(other)
        #expect(stripped?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(stripped?.value(forHTTPHeaderField: "X-Api-Key") == nil)
        #expect(stripped?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(await redirect(other, method: "POST") == nil)
    }
}

@Test @MainActor func errorMessagesDoNotEchoHeaderValues() {
    let store = MacStore(persistence: false)
    store.connectionHeaders = [CustomHeader(name: "X-Api-Key", value: "fixture-only-secret")]
    #expect(!store.errorMessage(MacFailure.message("refused fixture-only-secret")).contains("fixture-only-secret"))
    #expect(!store.errorMessage(APIError.http(statusCode: 403, body: #"{"error":"refused fixture-only-secret"}"#)).contains("fixture-only-secret"))
    #expect(!store.errorMessage(APIError.decoding(underlying: MacFailure.message("fixture-only-secret"))).contains("fixture-only-secret"))
}

@Test func emptyHeadersRemoveOnlyTheirOwnKeychainItem() throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.empty-headers.\(UUID())")
    let storage = ConnectionHeaderVault(vault: vault)
    let a = try ServerAddress.parse("https://a.invalid")
    let b = try ServerAddress.parse("https://b.invalid")
    defer { try? storage.clear(for: a); try? storage.clear(for: b); try? vault.delete(account: a.absoluteString) }
    try storage.save([CustomHeader(name: "Authorization", value: "Bearer fixture-only-a")], for: a)
    try storage.save([CustomHeader(name: "X-Token", value: "fixture-only-b")], for: b)
    try vault.save(Data("fixture-only-password".utf8), account: a.absoluteString)
    try storage.save(ConnectionHeaders.placeholders, for: a)
    #expect(try storage.load(for: a).isEmpty)
    #expect(try storage.load(for: b).first?.value == "fixture-only-b")
    #expect(try vault.read(account: a.absoluteString) != nil)
}
