import Testing
import Foundation
@testable import HermexMac

@Test func serverAddressRejectsCredentialsAndNonHTTP() throws {
    #expect(throws: Error.self) { try ServerAddress.parse("file:///etc") }
    #expect(throws: Error.self) { try ServerAddress.parse("https://user:secret@example.com") }
    #expect(throws: Error.self) { try ServerAddress.parse("https://example.com/?token=x") }
    #expect(try ServerAddress.parse(" http://127.0.0.1:8787/ ").absoluteString == "http://127.0.0.1:8787/")
}
