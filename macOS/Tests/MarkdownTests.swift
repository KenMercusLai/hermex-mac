import Foundation
import Testing

@Test func markdownHasRealListQuoteTableAndHeadingBlocks() {
    let blocks = MarkdownBlocks.parse("# Heading\n\n- **first**\n  - nested\n1. numbered\n\n> quoted\n> second\n\n| Name | Value |\n| :--- | ---: |\n| a | `b` |\n\n~~~swift\nlet x = 1\n~~~")
    #expect(blocks.map(\.kind) == [.heading(1), .listItem("•", 0), .listItem("•", 1), .listItem("1.", 0), .quote, .table, .code])
    #expect(blocks[5].rows == [["Name", "Value"], ["a", "`b`"]])
    #expect(blocks.last?.language == "swift")
    #expect(blocks.last?.text == "let x = 1")
}

@testable import HermexMac

@Test func markdownPreferenceDefaultsOnPersistsOffAndKeepsMedia() throws {
    let suite = "hermex-markdown-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(MarkdownPreference.enabled(in: defaults))
    defaults.set(false, forKey: MarkdownPreference.key)
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(!MarkdownPreference.enabled(in: reopened))
    for enabled in [true, false] {
        let parts = MessagePresentation.parts("# Heading\nMEDIA:/srv/fixture.md", markdown: enabled)
        #expect(parts.filter { $0.media != nil }.count == 1)
        #expect(parts.first?.markdown == enabled)
        #expect(parts.first?.text == "# Heading\n")
    }
}


@Test func markdownInlineUsesNativeEmphasisAndDiscardsUnsafeLinkAttributes() {
    let text = MarkdownBlocks.inline("**bold** *italic* `code` [safe](https://example.invalid) [bad](javascript:alert) [local](file:///srv/private.txt)")
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    #expect(text.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.invalid"])
    #expect(!MarkdownBlocks.safeLink(URL(string: "https://user:password@example.invalid")!))
}

@Test func fencedCodePreservesWhitespaceAndLanguage() {
    let blocks = MarkdownBlocks.parse("Hello **Mac**\n\n```swift\n  print(\"hello\")\n```\nAfter")
    #expect(blocks.count == 3)
    #expect(blocks[1].language == "swift")
    #expect(blocks[1].text == "  print(\"hello\")")
    #expect(blocks[2].text == "After")
}
