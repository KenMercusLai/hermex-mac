import Foundation

/// A server path is opaque: never percent-decode it or try to read it on this Mac.
struct MediaReference: Equatable, Sendable {
    let source: String
    let remoteURL: URL?
    init?(source: String) {
        guard !source.isEmpty, !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if source.hasPrefix("/") {
            guard !source.hasPrefix("//") else { return nil }
            self.remoteURL = nil
        } else {
            guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            self.remoteURL = url
        }
        self.source = source
    }
    var filename: String {
        let path = remoteURL?.path ?? source
        let name = path.components(separatedBy: "/").last ?? ""
        let safe = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" && $0 != "\\" }
        let value = String(String.UnicodeScalarView(safe))
        return value.isEmpty || value == "." || value == ".." ? "download" : value
    }
}

struct MediaSegment: Identifiable {
    let id: Int
    let text: String
    let media: MediaReference?
}

enum MediaTokens {
    /// Bare MEDIA consumes the remainder of its line (paths may contain spaces).
    /// Quotes, <…> and Markdown link destinations disambiguate surrounding prose.
    /// Code masks are applied before matching, including unfinished streaming fences.
    static func parse(_ text: String) -> [MediaSegment] {
        let ns = text as NSString
        var excluded = Set<Int>()
        var offset = 0
        var fence: (Character, Int)?
        var inlineTicks = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = String(line.dropFirst(min(indent, 3)))
            let first = trimmed.first
            let run = first.map { c in trimmed.prefix(while: { $0 == c }).count } ?? 0
            if let current = fence {
                excluded.formUnion(offset..<(offset + length))
                if indent <= 3, first == current.0, run >= current.1,
                   trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if indent <= 3, (first == "`" || first == "~"), run >= 3 {
                fence = (first!, run); excluded.formUnion(offset..<(offset + length))
            } else {
                let chars = Array(line.utf16)
                var i = 0
                while i < chars.count {
                    if chars[i] == 96 {
                        var end = i + 1
                        while end < chars.count && chars[end] == 96 { end += 1 }
                        let count = end - i
                        excluded.formUnion((offset + i)..<(offset + end))
                        if inlineTicks == 0 { inlineTicks = count } else if inlineTicks == count { inlineTicks = 0 }
                        i = end
                    } else {
                        if inlineTicks > 0 { excluded.insert(offset + i) }
                        i += 1
                    }
                }
            }
            offset += length + 1
        }
        let matches = try! NSRegularExpression(pattern: "MEDIA:").matches(in: text, range: NSRange(location: 0, length: ns.length))
        var segments: [MediaSegment] = [], cursor = 0
        for match in matches where match.range.location >= cursor && !excluded.contains(match.range.location) {
            let tokenStart = match.range.location, valueStart = NSMaxRange(match.range)
            var start = tokenStart
            var lineEnd = ns.range(of: "\n", range: NSRange(location: valueStart, length: ns.length - valueStart)).location
            if lineEnd == NSNotFound { lineEnd = ns.length }
            var begin = valueStart, end = lineEnd, consumedEnd = lineEnd
            func char(_ index: Int) -> String { ns.substring(with: NSRange(location: index, length: 1)) }
            // Matched wrapping delimiters belong to the download control, not to
            // adjacent raw/prose segments. Parentheses in path names stay exact.
            if begin < lineEnd, ["\"", "'", "<"].contains(char(begin)) {
                let opening = char(begin), close = opening == "<" ? ">" : opening
                let found = ns.range(of: close, range: NSRange(location: begin + 1, length: lineEnd - begin - 1)).location
                if found != NSNotFound { begin += 1; end = found; consumedEnd = found + 1 }
            } else if tokenStart > 0, char(tokenStart - 1) == "<" {
                let found = ns.range(of: ">", range: NSRange(location: begin, length: lineEnd - begin)).location
                if found != NSNotFound { start -= 1; end = found; consumedEnd = found + 1 }
            } else if tokenStart > 0, char(tokenStart - 1) == "(" {
                var depth = 1, position = begin
                while position < lineEnd {
                    if char(position) == "(" { depth += 1 }
                    if char(position) == ")" { depth -= 1; if depth == 0 { break } }
                    position += 1
                }
                if depth == 0 {
                    end = position; consumedEnd = position + 1
                    let prefix = ns.substring(with: NSRange(location: cursor, length: tokenStart - cursor))
                    if let label = prefix.range(of: #"!?\[[^\]\n]*\]\($"#, options: .regularExpression) {
                        start = cursor + (prefix[..<label.lowerBound] as NSString).length
                    }
                }
            }
            let source = ns.substring(with: NSRange(location: begin, length: end - begin)).trimmingCharacters(in: .whitespaces)
            guard let media = MediaReference(source: source) else { continue }
            if start > cursor { segments.append(.init(id: segments.count, text: ns.substring(with: NSRange(location: cursor, length: start - cursor)), media: nil)) }
            segments.append(.init(id: segments.count, text: ns.substring(with: NSRange(location: start, length: consumedEnd - start)), media: media))
            cursor = consumedEnd
        }
        if cursor < ns.length { segments.append(.init(id: segments.count, text: ns.substring(from: cursor), media: nil)) }
        return segments
    }
}
