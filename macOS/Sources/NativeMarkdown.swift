import SwiftUI
import AppKit

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable { case prose, heading(Int), listItem(String, Int), quote, table, code, rule }
    var id: Int
    var text: String
    var language: String?
    var kind: Kind = .prose
    var rows: [[String]] = []
}

/// A deliberately native, non-HTML Markdown subset. Inline parsing is Foundation's
/// Markdown parser; block layout is explicit SwiftUI (no web view/JS/image fetches).
enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = [], prose: [String] = []
        func add(_ text: String, _ kind: MarkdownBlock.Kind, language: String? = nil, rows: [[String]] = []) {
            blocks.append(.init(id: blocks.count, text: text, language: language, kind: kind, rows: rows))
        }
        func flush() { if !prose.isEmpty { add(prose.joined(separator: "\n"), .prose); prose = [] } }
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
            // Preserve escaped pipes rather than splitting their cells.
            return value.replacingOccurrences(of: "\\|", with: "\u{001F}").components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{001F}", with: "|")
            }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent <= 3, let c = trimmed.first, c == "`" || c == "~", trimmed.prefix(while: { $0 == c }).count >= 3 {
                flush()
                let count = trimmed.prefix(while: { $0 == c }).count
                let language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.prefix(while: { $0 == c }).count >= count && candidate.drop(while: { $0 == c }).isEmpty { break }
                    code.append(lines[i]); i += 1
                }
                add(code.joined(separator: "\n"), .code, language: language); i += 1; continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if i + 1 < lines.count, line.contains("|"), cells(lines[i + 1]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                flush(); var rows = [cells(line)]; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                add("", .table, rows: rows); continue
            }
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                flush(); let level = trimmed.prefix(while: { $0 == "#" }).count
                add(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces), .heading(level))
            } else if let range = trimmed.range(of: #"^(?:[-+*]|[0-9]+[.)])\s+"#, options: .regularExpression) {
                flush(); let marker = trimmed[range].trimmingCharacters(in: .whitespaces)
                add(String(trimmed[range.upperBound...]), .listItem(["-", "+", "*"].contains(marker) ? "•" : marker, indent / 2))
            } else if trimmed.hasPrefix(">") {
                flush(); var quotes: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quotes.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                add(quotes.joined(separator: "\n"), .quote); continue
            } else if ["---", "***", "___"].contains(trimmed) { flush(); add("", .rule) }
            else { prose.append(line) }
            i += 1
        }
        flush(); return blocks
    }
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Foundation doesn't execute links or load images. Strip unsafe link
        // attributes as well as guarding OpenURL so copy/accessibility stays safe.
        for run in result.runs { if let link = run.link, !safeLink(link) { result[run.range].link = nil } }
        return result
    }
    static func safeLink(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
    }
}

func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct NativeMarkdown: View {
    let text: String
    private func inline(_ text: String) -> some View {
        Text(MarkdownBlocks.inline(text)).textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlocks.parse(text)) { block in
                switch block.kind {
                case .code:
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(block.language?.isEmpty == false ? block.language! : "Code").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { copyText(block.text) } label: { Label("Copy code", systemImage: "doc.on.doc") }.buttonStyle(.borderless).font(.caption)
                        }.padding(10)
                        Divider()
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(12) }
                    }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                case .heading(let level): inline(block.text).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                case .listItem(let marker, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 10) { Text(marker).monospacedDigit(); inline(block.text) }.padding(.leading, CGFloat(min(depth, 12) * 18))
                case .quote:
                    HStack(alignment: .top, spacing: 12) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3); inline(block.text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .table:
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(block.rows.enumerated()), id: \.offset) { row, cells in
                                GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    inline(cell).fontWeight(row == 0 ? .semibold : .regular).padding(9).background(row == 0 ? Color.primary.opacity(0.08) : Color.clear).border(Color.primary.opacity(0.12), width: 0.5)
                                } }
                            }
                        }
                    }
                case .rule: Divider()
                case .prose: inline(block.text)
                }
            }
        }.environment(\.openURL, OpenURLAction { MarkdownBlocks.safeLink($0) ? .systemAction : .discarded })
    }
}
