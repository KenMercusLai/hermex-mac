import Foundation

struct RunTool: Identifiable {
    let id: String
    var name: String
    var preview: String
    var complete: Bool
    var failed: Bool
}
struct RunProjection {
    let displayID = UUID()
    private(set) var toolDisplayPhase: ToolDisplayPhase = .settled
    private(set) var toolDisplayRevision = 0
    private mutating func displayPhase(_ phase: ToolDisplayPhase) {
        if toolDisplayPhase != phase { toolDisplayPhase = phase; toolDisplayRevision += 1 }
    }
    var text = ""
    var reasoning = ""
    var tools: [RunTool] = []
    var sequence: Int?
    var approval: PendingApproval?
    var clarification: PendingClarification?
    var error: String?
    var completedSession: SessionDetail?
    /// `done` may precede other journal events; only terminal frames close transport.
    mutating func apply(_ event: SSEEvent, sequence incoming: Int?) -> Bool {
        if let incoming {
            if let sequence, incoming <= sequence { return false }
            sequence = incoming
        }
        switch event {
        case .token(let value):
            text += value
            if value.macNonEmpty != nil { displayPhase(.reply) }
        case .reasoning(let value): reasoning += value
        case .interimAssistant(let value):
            if value.alreadyStreamed != true, let value = value.text { text += value + "\n\n" }
            if value.text?.macNonEmpty != nil { displayPhase(.reply) }
        case .toolStarted(let tool), .toolCompleted(let tool):
            let isComplete: Bool
            if case .toolCompleted = event { isComplete = true } else { isComplete = false }
            let id = tool.stableID ?? tool.name ?? UUID().uuidString
            if !isComplete || !tools.contains(where: { $0.id == id }) { displayPhase(.executing) }
            let previous = tools.first { $0.id == id }
            let entry = RunTool(id: id, name: tool.name ?? previous?.name ?? "Tool", preview: tool.preview ?? previous?.preview ?? "", complete: isComplete, failed: tool.isError ?? previous?.failed ?? false)
            if let index = tools.firstIndex(where: { $0.id == id }) { tools[index] = entry } else { tools.append(entry) }
        case .approvalPending(let value): approval = value.pending
        case .clarificationPending(let value): clarification = value.pending
        case .done(let value): completedSession = value.session
        case .error(let value): error = value; displayPhase(.settled); return true
        case .transportError(let value): error = value; return true
        case .cancelled, .streamEnd: displayPhase(.settled); return true
        default: break
        }
        return false
    }
}
