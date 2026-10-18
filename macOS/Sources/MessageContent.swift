import SwiftUI

enum MarkdownPreference {
    static let key = "renderMarkdown"
    static func enabled(in defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
}

enum MessagePresentation {
    struct Part: Identifiable {
        let id: Int
        let text: String
        let media: MediaReference?
        let markdown: Bool
    }
    static func parts(_ text: String, markdown: Bool) -> [Part] {
        MediaTokens.parse(text).map { Part(id: $0.id, text: $0.text, media: $0.media, markdown: markdown) }
    }
}

/// Both history and the streaming projection observe the same persistent switch.
/// MEDIA is intentionally independent of Markdown, with no fetch during rendering.
struct MessageContent: View {
    let text: String
    var download: (MediaReference) -> Void
    @AppStorage(MarkdownPreference.key) private var markdown = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MessagePresentation.parts(text, markdown: markdown)) { part in
                if let media = part.media {
                    Button { download(media) } label: { Label("Download \(media.filename)…", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.link).help("Choose where to save before downloading")
                        .accessibilityIdentifier("media-save-download")
                } else if part.markdown { NativeMarkdown(text: part.text) }
                else { Text(part.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}

struct MarkdownSettingsView: View {
    @AppStorage(MarkdownPreference.key) private var markdown = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Messages").font(.headline)
            Toggle("Render Markdown", isOn: $markdown).accessibilityIdentifier("render-markdown")
            Text("Applies immediately to existing and streaming replies. When off, Markdown is shown as raw text; MEDIA download links remain available.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
