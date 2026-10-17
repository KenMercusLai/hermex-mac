import Testing
@testable import HermexMac

@Test func runReplayDeduplicatesAndCompletesOnlyAtTerminal() {
    var run = RunProjection()
    #expect(run.apply(.token("Hello"), sequence: 1) == false)
    #expect(run.apply(.token("Hello"), sequence: 1) == false)
    #expect(run.text == "Hello")
    #expect(run.apply(.reasoning("Consider"), sequence: 2) == false)
    #expect(run.reasoning == "Consider")
    #expect(run.apply(.done(DoneStreamEvent()), sequence: 3) == false)
    #expect(run.apply(.streamEnd, sequence: 4) == true)
    #expect(run.sequence == 4)
}
