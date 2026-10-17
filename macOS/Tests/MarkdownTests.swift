import Testing
@testable import HermexMac

@Test func fencedCodePreservesWhitespaceAndLanguage() {
    let blocks = MarkdownBlocks.parse("Hello **Mac**\n\n```swift\n  print(\"hello\")\n```\nAfter")
    #expect(blocks.count == 3)
    #expect(blocks[1].language == "swift")
    #expect(blocks[1].text == "  print(\"hello\")")
    #expect(blocks[2].text == "After")
}
