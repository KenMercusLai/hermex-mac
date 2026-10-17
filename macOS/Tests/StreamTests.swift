import Testing
import Foundation
@testable import HermexMac

@Test func sseFramingPreservesMultiLineAndCursor() throws {
    var parser = SSEFrameParser()
    #expect(parser.line(": heartbeat") == nil)
    #expect(parser.line("id: run:12") == nil)
    #expect(parser.line("event: token") == nil)
    #expect(parser.line("data: {\"text\":") == nil)
    #expect(parser.line("data: \"hello\"}") == nil)
    let parsed = parser.line("")
    let frame = try #require(parsed)
    #expect(frame.id == "run:12")
    #expect(frame.type == "token")
    #expect(SSEEventDecoder.decode(eventType: frame.type, data: frame.data) == .token("hello"))
    #expect(parser.line("") == nil)
}
