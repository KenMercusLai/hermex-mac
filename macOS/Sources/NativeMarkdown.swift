import SwiftUI
import AppKit

struct MarkdownBlock: Identifiable {
    var id: Int
    var text: String
    /// nil = prose; empty string = unlabeled code fence.
    var language: String?
}
enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines: [String] = []
        var language: String?
        func flush() {
            let value = lines.joined(separator: "\n")
            if !value.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, text: value, language: language)) }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                if language == nil { language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                else { language = nil }
            } else { lines.append(line) }
        }
        flush()
        return blocks
    }
}

func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct NativeMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlocks.parse(text)) { block in
                if let language = block.language {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { copyText(block.text) } label: { Label("Copy code", systemImage: "doc.on.doc") }.buttonStyle(.borderless).font(.caption)
                        }.padding(10)
                        Divider()
                        ScrollView(.horizontal) {
                            Text(block.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                } else {
                    ForEach(Array(block.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        let heading = paragraph.hasPrefix("#")
                        let prose = heading ? paragraph.drop(while: { $0 == "#" || $0 == " " }).description : paragraph
                        Text((try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose))
                            .font(heading ? .title3.weight(.semibold) : .body)
                            .textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.environment(\.openURL, OpenURLAction { url in
            guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }
}
