import Foundation

enum ToolDisplayPhase: Equatable { case settled, executing, reply }

enum ToolDisplayMode: String, CaseIterable {
    case collapsed, whileExecuting, expanded
    static let key = "toolDisplayMode"
    static func stored(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .collapsed
    }
}

/// Includes source/run identity so a recycled row cannot inherit another tool's toggle.
struct ToolDisclosureContext: Equatable {
    var scope: String
    var mode: ToolDisplayMode
    var phase: ToolDisplayPhase
    var revision: Int
}

struct ToolDisclosureState {
    private var context: ToolDisclosureContext?
    private var manual: Bool?
    func isExpanded(in context: ToolDisclosureContext) -> Bool {
        if self.context == context, let manual { return manual }
        return context.mode == .expanded || (context.mode == .whileExecuting && context.phase == .executing)
    }
    mutating func synchronize(with context: ToolDisclosureContext) {
        if self.context != context { self.context = context; manual = nil }
    }
    mutating func toggle(in context: ToolDisclosureContext) {
        synchronize(with: context)
        manual = !isExpanded(in: context)
    }
}

struct ToolDisplayItem: Identifiable {
    enum Status { case running, completed, failed }
    let id: String
    let name: String
    let detail: String
    let status: Status
    var phase: ToolDisplayPhase = .settled
    var revision = 0
    var runID: UUID?
}

/// Presentation only: prefer full history results, then live events, then saved snippets.
/// Exact server call IDs suppress lower-priority sources, never distinct history payloads.
struct ToolTranscriptPresentation {
    struct HistoryRow: Identifiable {
        let id: String
        let message: ChatMessage
        let tool: ToolDisplayItem?
    }
    var history: [HistoryRow] = []
    var recorded: [ToolDisplayItem] = []
    var live: [ToolDisplayItem] = []

    /// Tagged JSON components keep server IDs disjoint from generated identities,
    /// even when an exact server ID contains separators or encoded identity text.
    private static func rowID(_ components: String...) -> String {
        String(decoding: try! JSONEncoder().encode(components), as: UTF8.self)
    }

    init(messages: [ChatMessage], recorded: [PersistedToolCall], run: RunProjection, active: Bool) {
        var names: [String: String] = [:]
        for tool in recorded { if let id = tool.tid, let name = tool.name { names[id] = name } }
        for message in messages {
            for call in message.toolCalls ?? [] {
                guard case .object(let fields) = call,
                      case .string(let id) = fields["id"],
                      case .object(let function) = fields["function"],
                      case .string(let name) = function["name"] else { continue }
                names[id] = name
            }
        }
        for tool in run.tools { names[tool.id] = tool.name }
        let liveIDs = Set(run.tools.map(\.id))
        var historyIDs: Set<String> = []
        func livePhase(_ item: ToolDisplayItem, callID: String?) -> ToolDisplayItem {
            var item = item
            if active, let callID, liveIDs.contains(callID) {
                item.phase = run.toolDisplayPhase; item.revision = run.toolDisplayRevision; item.runID = run.displayID
            }
            return item
        }
        var occurrences: [String: Int] = [:]
        for message in messages {
            if message.role == "assistant", message.content?.macNonEmpty == nil,
               message.reasoning?.macNonEmpty == nil, (message.attachments ?? []).isEmpty,
               (message.contentParts ?? []).isEmpty { continue }
            let occurrence = occurrences[message.id, default: 0]
            occurrences[message.id] = occurrence + 1
            let messageID = Self.rowID("message", message.id, String(occurrence))
            var tool: ToolDisplayItem?
            if message.role == "tool" {
                let callID = message.toolCallId ?? message.toolUseId
                if let callID { historyIDs.insert(callID) }
                let saved = recorded.first { $0.tid != nil && $0.tid == callID }
                let liveFailed = run.tools.contains { $0.id == callID && $0.failed }
                // Every payload keeps its own stable identity, including repeated exact calls.
                let id = callID.map { Self.rowID("history", "call", $0, message.id, String(occurrence)) }
                    ?? Self.rowID("history", "message", message.id, String(occurrence))
                tool = livePhase(ToolDisplayItem(id: id, name: message.name ?? callID.flatMap { names[$0] } ?? "Tool", detail: message.content ?? "", status: saved?.isError == true || liveFailed ? .failed : .completed), callID: callID)
            }
            history.append(HistoryRow(id: tool?.id ?? messageID, message: message, tool: tool))
        }
        var seen = historyIDs.union(liveIDs)
        for (index, tool) in recorded.enumerated() {
            if let id = tool.tid, !seen.insert(id).inserted { continue }
            let id = tool.tid.map { Self.rowID("recorded", "call", $0) } ?? Self.rowID("recorded", "index", String(index))
            self.recorded.append(ToolDisplayItem(id: id, name: tool.name ?? "Tool", detail: tool.snippet ?? "", status: tool.isError == true ? .failed : .completed))
        }
        for tool in run.tools where !historyIDs.contains(tool.id) {
            live.append(livePhase(ToolDisplayItem(id: Self.rowID("live", "call", tool.id), name: tool.name, detail: tool.preview, status: tool.failed ? .failed : tool.complete ? .completed : .running), callID: tool.id))
        }
    }
}
