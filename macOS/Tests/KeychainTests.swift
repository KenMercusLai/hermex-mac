import Testing
import Foundation
@testable import HermexMac

@Test func keychainRoundTripHasIsolatedAccounts() throws {
    let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.tests.\(UUID())")
    defer { try? vault.delete(account: "a"); try? vault.delete(account: "b") }
    try vault.save(Data("test-only-password".utf8), account: "a")
    #expect(try vault.read(account: "a") == Data("test-only-password".utf8))
    #expect(try vault.read(account: "b") == nil)
    try vault.delete(account: "a")
    #expect(try vault.read(account: "a") == nil)
}
