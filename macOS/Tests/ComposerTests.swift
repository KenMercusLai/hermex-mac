import Testing
@testable import HermexMac

@Test func composerNeverSendsWhileIMEHasMarkedText() {
    #expect(ComposerPolicy.shouldSend(returnKey: true, command: false, shift: false, marked: true) == false)
    #expect(ComposerPolicy.shouldSend(returnKey: true, command: true, shift: false, marked: true) == false)
    #expect(ComposerPolicy.shouldSend(returnKey: true, command: false, shift: false, marked: false))
    #expect(ComposerPolicy.shouldSend(returnKey: true, command: false, shift: true, marked: false) == false)
    #expect(ComposerPolicy.shouldSend(returnKey: true, command: true, shift: false, marked: false))
}
