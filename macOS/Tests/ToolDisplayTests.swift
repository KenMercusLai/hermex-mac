import Foundation
import SwiftUI
import AppKit
import Testing
@testable import HermexMac

@Test func toolDisplayDefaultInvalidFallbackAndPersistence() throws {
    let suite = "hermex-tool-display-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ToolDisplayMode.stored(in: defaults) == .collapsed)
    defaults.set("invalid", forKey: ToolDisplayMode.key)
    #expect(ToolDisplayMode.stored(in: defaults) == .collapsed)
    for mode in ToolDisplayMode.allCases {
        defaults.set(mode.rawValue, forKey: ToolDisplayMode.key)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ToolDisplayMode.stored(in: reopened) == mode)
    }
    #expect(ToolDisplayMode.allCases.count == 3)
}

private func displayTool(_ id: String = "a") -> ToolStreamEvent {
    ToolStreamEvent(eventType: nil, name: "read_file", preview: "README.md", args: nil, duration: nil, isError: nil, stableID: id)
}

@Test func toolDisplayTracksExecutionReplyAndNewToolPhaseNotWholeStream() {
    var run = RunProjection()
    _ = run.apply(.toolStarted(displayTool()), sequence: 1)
    #expect(run.toolDisplayPhase == .executing)
    let execution = run.toolDisplayRevision
    _ = run.apply(.toolCompleted(displayTool()), sequence: 2)
    _ = run.apply(.reasoning("thinking"), sequence: 3)
    _ = run.apply(.token(" \n"), sequence: 4)
    #expect(run.toolDisplayRevision == execution)
    _ = run.apply(.interimAssistant(.init(text: "Here is the result")), sequence: 5)
    #expect(run.toolDisplayPhase == .reply)
    #expect(run.toolDisplayRevision > execution)
    let reply = run.toolDisplayRevision
    _ = run.apply(.token(" continued"), sequence: 6)
    _ = run.apply(.toolCompleted(displayTool()), sequence: 7)
    #expect(run.toolDisplayRevision == reply)
    _ = run.apply(.toolStarted(displayTool("b")), sequence: 8)
    #expect(run.toolDisplayPhase == .executing)
    #expect(run.toolDisplayRevision > reply)
    let secondExecution = run.toolDisplayRevision
    _ = run.apply(.done(DoneStreamEvent()), sequence: 9)
    #expect(run.toolDisplayRevision == secondExecution)
    _ = run.apply(.token("Final answer"), sequence: 10)
    #expect(run.toolDisplayPhase == .reply)
    let replayTerminal = run.apply(.toolStarted(displayTool("c")), sequence: 8)
    #expect(replayTerminal == false)
    #expect(run.toolDisplayPhase == .reply)
    _ = run.apply(.streamEnd, sequence: 11)
    #expect(run.toolDisplayPhase == .settled)
    // An empty / already-streamed interim marker is not a new visible reply.
    var paused = RunProjection()
    _ = paused.apply(.toolStarted(displayTool()), sequence: 1)
    _ = paused.apply(.interimAssistant(.init(alreadyStreamed: true)), sequence: 2)
    #expect(paused.toolDisplayPhase == .executing)
    _ = paused.apply(.transportError("offline"), sequence: 3)
    #expect(paused.toolDisplayPhase == .executing)
    _ = paused.apply(.cancelled, sequence: 4)
    #expect(paused.toolDisplayPhase == .settled)
}

@Test func toolDisplayManualTogglesRespectModePhaseAndSourceBoundaries() {
    var state = ToolDisclosureState()
    let executing = ToolDisclosureContext(scope: "server-A/session-A/live/run1/tool-a", mode: .whileExecuting, phase: .executing, revision: 1)
    #expect(state.isExpanded(in: executing))
    state.toggle(in: executing)
    #expect(!state.isExpanded(in: executing))
    // Completion/preview/token redraws in the same phase do not reset a manual toggle.
    state.synchronize(with: executing)
    #expect(!state.isExpanded(in: executing))
    var reply = executing; reply.phase = .reply; reply.revision = 2
    state.synchronize(with: reply)
    #expect(!state.isExpanded(in: reply))
    state.toggle(in: reply)
    #expect(state.isExpanded(in: reply))
    var next = executing; next.revision = 3
    state.synchronize(with: next)
    #expect(state.isExpanded(in: next))
    for mode in ToolDisplayMode.allCases {
        var changed = next; changed.mode = mode
        state.synchronize(with: changed)
        #expect(state.isExpanded(in: changed) == (mode != .collapsed))
        state.toggle(in: changed)
        #expect(state.isExpanded(in: changed) == (mode == .collapsed))
        var history = changed; history.phase = .settled; history.scope = "server-A/session-A/history/tool-a"
        #expect(state.isExpanded(in: history) == (mode == .expanded))
    }
    var otherSession = executing; otherSession.scope = "server-A/session-B/live/run1/tool-a"
    state.synchronize(with: executing); state.toggle(in: executing)
    #expect(!state.isExpanded(in: executing))
    state.synchronize(with: otherSession)
    #expect(state.isExpanded(in: otherSession))
    state.synchronize(with: executing)
    #expect(state.isExpanded(in: executing))
    var collapsed = executing; collapsed.mode = .collapsed
    state.synchronize(with: collapsed); state.toggle(in: collapsed)
    var expanded = collapsed; expanded.mode = .expanded
    state.synchronize(with: expanded); state.toggle(in: expanded)
    state.synchronize(with: collapsed)
    #expect(!state.isExpanded(in: collapsed))
}

@Test func toolDisplayUnifiesHistoryFallbackAndLiveWithoutDuplicateIDs() {
    let scaffold = ChatMessage(role: "assistant", content: "", timestamp: nil, messageId: "scaffold", toolCalls: [.object(["id": .string("a"), "function": .object(["name": .string("read_file")])])])
    let history = ChatMessage(role: "tool", content: "Full result", timestamp: nil, messageId: "result", toolCallId: "a")
    let recorded = [PersistedToolCall(name: "read_file", snippet: "Truncated", tid: "a", assistantMsgIdx: 0, args: nil),
                    PersistedToolCall(name: "search", snippet: "A saved snippet", tid: "old", assistantMsgIdx: nil, args: nil, isError: true)]
    var run = RunProjection()
    _ = run.apply(.toolStarted(displayTool()), sequence: 1)
    let projection = ToolTranscriptPresentation(messages: [scaffold, history], recorded: recorded, run: run, active: true)
    #expect(projection.history.count == 1)
    #expect(projection.history.first?.tool?.name == "read_file")
    #expect(projection.history.first?.tool?.detail == "Full result")
    #expect(projection.history.first?.tool?.phase == .executing)
    #expect(projection.recorded.map(\.name) == ["search"])
    #expect(projection.recorded.first?.status == .failed)
    #expect(projection.recorded.first?.phase == .settled)
    #expect(projection.live.isEmpty)
    _ = run.apply(.token("Answer"), sequence: 2)
    let reply = ToolTranscriptPresentation(messages: [history], recorded: recorded, run: run, active: true)
    #expect(reply.history.first?.tool?.phase == .reply)
    let settled = ToolTranscriptPresentation(messages: [history], recorded: recorded, run: run, active: false)
    #expect(settled.history.first?.tool?.phase == .settled)
    let liveOnly = ToolTranscriptPresentation(messages: [], recorded: recorded, run: run, active: true)
    #expect(liveOnly.live.count == 1)
    #expect(liveOnly.recorded.map(\.name) == ["search"])
    #expect(liveOnly.live.first?.id != projection.history.first?.tool?.id)
    let failure = ToolStreamEvent(eventType: nil, name: nil, preview: nil, args: nil, duration: nil, isError: true, stableID: "a")
    _ = run.apply(.toolCompleted(failure), sequence: 3)
    let failedHistory = ToolTranscriptPresentation(messages: [history], recorded: recorded, run: run, active: true)
    #expect(failedHistory.history.first?.tool?.status == .failed)
}

/// Exercise disclosure state keyed exactly as SwiftUI keys each rendered row.
private func expectIndependentToolRows(_ items: [ToolDisplayItem]) {
    #expect(Set(items.map(\.id)).count == items.count)
    for mode in ToolDisplayMode.allCases {
        var states: [String: ToolDisclosureState] = [:]
        let contexts = items.map { ToolDisclosureContext(scope: $0.id, mode: mode, phase: $0.phase, revision: $0.revision) }
        for (index, context) in contexts.enumerated() {
            var state = states[context.scope, default: ToolDisclosureState()]
            state.toggle(in: context)
            states[context.scope] = state
            for (otherIndex, other) in contexts.enumerated() {
                let defaultExpanded = other.mode == .expanded || (other.mode == .whileExecuting && other.phase == .executing)
                #expect(states[other.scope, default: ToolDisclosureState()].isExpanded(in: other) == (otherIndex <= index ? !defaultExpanded : defaultExpanded))
            }
        }
    }
}

@Test func toolDisplayRecordedNumericServerIDsDoNotAliasGeneratedIndices() {
    let saved = [nil, "0", nil, "2", "recorded/index/0", #"["recorded","index","0"]"#, " 0", ""].enumerated().map { index, id in
        PersistedToolCall(name: "read_file", snippet: "Saved result \(index)", tid: id, assistantMsgIdx: nil, args: nil)
    }
    let projection = ToolTranscriptPresentation(messages: [], recorded: saved, run: RunProjection(), active: false)
    #expect(projection.recorded.count == saved.count)
    #expect(projection.recorded.map(\.detail) == saved.map { $0.snippet ?? "" })
    expectIndependentToolRows(projection.recorded)
    let appended = ToolTranscriptPresentation(messages: [], recorded: saved + [saved[0]], run: RunProjection(), active: false)
    #expect(Array(appended.recorded.prefix(saved.count).map(\.id)) == projection.recorded.map(\.id))
}

@Test func toolDisplayHistoryRetainsRepeatedCallPayloadsWithStableIndependentIdentities() throws {
    let first = ChatMessage(role: "tool", content: "First full result", timestamp: nil, messageId: "first", toolCallId: "0", contentParts: [.object(["type": .string("text"), "text": .string("Keep first parts")])], reasoning: "First reason", attachments: [.init(name: "first.txt")])
    let second = ChatMessage(role: "tool", content: "Second full result", timestamp: nil, messageId: "second", toolCallId: "0", reasoning: "Second reason", attachments: [.init(name: "second.txt")])
    let idless = ChatMessage(role: "tool", content: "IDless payload", timestamp: nil, messageId: "x")
    let delimiterIDs = ["x/0", "a/b", "a", #"["history","message","x","0"]"#, "\"/,\\\n", "", " 0"]
    let adversarial = delimiterIDs.enumerated().map { index, id in
        ChatMessage(role: "tool", content: "Adversarial result \(index)", timestamp: nil, messageId: index == 1 ? "c" : index == 2 ? "b/c" : "message/\(index)", toolUseId: id, reasoning: "Reason \(index)", attachments: [.init(name: "result-\(index).txt")])
    }
    let ordinary = ChatMessage(role: "assistant", content: "Keep ordinary reply", timestamp: nil, messageId: #"["history","call","0","first","0"]"#)
    let messages = [first, second, first, idless] + adversarial + [ordinary, ordinary]
    let callIDs = ["0"] + delimiterIDs
    let saved = callIDs.map { PersistedToolCall(name: "read_file", snippet: "Suppress only this exact ID", tid: $0, assistantMsgIdx: nil, args: nil) }
        + [PersistedToolCall(name: "read_file", snippet: "Keep space-suffixed ID", tid: "0 ", assistantMsgIdx: nil, args: nil)]
    var run = RunProjection()
    _ = run.apply(.toolStarted(displayTool("0")), sequence: 1)
    // Bypass the stream decoder's empty-ID fallback: this tests presentation's exact-ID contract.
    run.tools = (callIDs + ["live/only", #"["recorded","index","0"]"#]).map {
        RunTool(id: $0, name: "read_file", preview: "README.md", complete: false, failed: false)
    }
    let projection = ToolTranscriptPresentation(messages: messages, recorded: saved, run: run, active: true)
    // Whole-message equality proves no content, reasoning, parts or attachments were merged away.
    #expect(projection.history.map(\.message) == messages)
    #expect(projection.history.compactMap(\.tool).map(\.detail) == messages.filter { $0.role == "tool" }.map { $0.content ?? "" })
    #expect(projection.recorded.map(\.detail) == ["Keep space-suffixed ID"])
    #expect(projection.live.count == 2)
    let allIDs = projection.history.map(\.id) + projection.recorded.map(\.id) + projection.live.map(\.id)
    #expect(Set(allIDs).count == allIDs.count)
    for row in projection.history {
        if let tool = row.tool { #expect(row.id == tool.id) }
    }
    let items = projection.history.compactMap(\.tool) + projection.recorded + projection.live
    expectIndependentToolRows(items)
    let appended = ToolTranscriptPresentation(messages: messages + [first, second, idless, ordinary], recorded: saved, run: run, active: true)
    #expect(Array(appended.history.prefix(messages.count).map(\.id)) == projection.history.map(\.id))
    #expect(Set(appended.history.map(\.id)).count == appended.history.count)
    #expect(appended.history.map(\.message) == messages + [first, second, idless, ordinary])
    // A manual toggle on an existing duplicate survives appending more occurrences.
    let previous = try #require(projection.history[2].tool)
    let next = try #require(appended.history[2].tool)
    let context = ToolDisclosureContext(scope: previous.id, mode: .collapsed, phase: previous.phase, revision: previous.revision)
    var state = ToolDisclosureState()
    state.toggle(in: context)
    let appendedContext = ToolDisclosureContext(scope: next.id, mode: .collapsed, phase: next.phase, revision: next.revision)
    state.synchronize(with: appendedContext)
    #expect(state.isExpanded(in: appendedContext))
}

@Test func toolDisplayPreservesPayloadRowsAndDistinctIDlessCalls() {
    let empty = ChatMessage(role: "assistant", content: " \n", timestamp: nil, messageId: "empty")
    let reasoning = ChatMessage(role: "assistant", content: nil, timestamp: nil, messageId: "reasoning", reasoning: "Retain reasoning")
    let text = ChatMessage(role: "assistant", content: "MEDIA:/fixture/report.md", timestamp: nil, messageId: "media")
    let parts = ChatMessage(role: "assistant", content: nil, timestamp: nil, messageId: "parts", contentParts: [.object(["type": .string("image_url")])])
    let result = ChatMessage(role: "tool", content: "same result", timestamp: nil, messageId: nil, name: "read_file")
    let saved = PersistedToolCall(name: "read_file", snippet: "same result", tid: nil, assistantMsgIdx: nil, args: nil)
    let projection = ToolTranscriptPresentation(messages: [empty, reasoning, text, parts, result, result], recorded: [saved, saved], run: RunProjection(), active: false)
    #expect(projection.history.map(\.message) == [reasoning, text, parts, result, result])
    #expect(Set(projection.history.map(\.id)).count == projection.history.count)
    #expect(projection.recorded.count == 2)
    #expect(Set(projection.recorded.map(\.id)).count == 2)
    #expect(projection.history.suffix(2).allSatisfy { $0.tool?.phase == .settled })
}

@MainActor @Test func toolDisplayNativeButtonIsCompactAndModesRenderDetails() throws {
    _ = NSApplication.shared
    let item = ToolDisplayItem(id: "history/test", name: "read_file", detail: "First line\nSecond line\nThird line\nFourth line\nFifth line", status: .completed)
    func size(_ mode: ToolDisplayMode, phase: ToolDisplayPhase) -> NSSize {
        var item = item; item.phase = phase
        return NSHostingView(rootView: ToolDetailButton(item: item, scope: "synthetic", mode: mode).frame(width: 600)).fittingSize
    }
    let collapsed = size(.collapsed, phase: .settled)
    let expanded = size(.expanded, phase: .settled)
    #expect(collapsed.height > 10)
    #expect(collapsed.height <= 40)
    #expect(expanded.height > collapsed.height + 60)
    #expect(size(.whileExecuting, phase: .executing).height == expanded.height)
    #expect(size(.whileExecuting, phase: .reply).height == collapsed.height)
    #expect(size(.whileExecuting, phase: .settled).height == collapsed.height)
}

@MainActor @Test func toolDisplayHistoryRowHasOnlyTheCompactHeaderAndRetainsAttachments() {
    _ = NSApplication.shared
    let message = ChatMessage(role: "tool", content: "First line\nSecond line", timestamp: nil, messageId: "tool", name: "read_file")
    let item = ToolDisplayItem(id: "history/tool", name: "read_file", detail: message.content!, status: .completed)
    let row = MessageRow(message: message, tool: item, toolScope: "synthetic", toolMode: .collapsed, download: { _ in })
    let size = NSHostingView(rootView: row.frame(width: 600)).fittingSize
    #expect(size.height <= 40)
    let attached = ChatMessage(role: "tool", content: "result", timestamp: nil, messageId: "attached", attachments: [.init(name: "fixture.txt")])
    let attachedRow = MessageRow(message: attached, tool: item, toolScope: "synthetic", toolMode: .collapsed, download: { _ in })
    #expect(NSHostingView(rootView: attachedRow.frame(width: 600)).fittingSize.height > size.height)
}

@Test func toolDisplayStableIDsKeepRepeatedNamesSeparateAndCompletionRetainsDetails() {
    var run = RunProjection()
    _ = run.apply(.toolStarted(displayTool("a")), sequence: 1)
    _ = run.apply(.toolStarted(displayTool("b")), sequence: 2)
    let completion = ToolStreamEvent(eventType: nil, name: nil, preview: nil, args: nil, duration: nil, isError: true, stableID: "a")
    _ = run.apply(.toolCompleted(completion), sequence: 3)
    #expect(run.tools.count == 2)
    #expect(run.tools.first?.name == "read_file")
    #expect(run.tools.first?.preview == "README.md")
    let items = ToolTranscriptPresentation(messages: [], recorded: [], run: run, active: true).live
    #expect(items.map(\.status) == [.failed, .running])
    #expect(Set(items.map(\.id)).count == 2)
}

/// Programmatic offscreen rendering only: no user's application, login, or screen capture.
@MainActor @Test func toolDisplayRendersSyntheticConversationAndSettings() throws {
    _ = NSApplication.shared
    let suite = "hermex-tool-render-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MacStore(persistence: false)
    let session = try JSONDecoder().decode(SessionDetail.self, from: Data(#"{"session_id":"synthetic-tools","title":"Synthetic tool display proof","messages":[{"role":"assistant","content":"","toolCalls":[{"id":"history-a","function":{"name":"read_file"}}]},{"role":"tool","name":"read_file","toolCallId":"history-a","content":"Synthetic README contents.\nNo private conversation data."},{"role":"tool","name":"terminal","toolCallId":"history-b","content":"All fixture checks passed."},{"role":"assistant","content":"The saved checks passed. **Markdown stays enabled.**"}],"toolCalls":[{"tid":"history-a","name":"read_file","snippet":"Duplicate snippet, hidden by exact ID"},{"tid":"recorded-only","name":"web_search","snippet":"A recorded-only synthetic search preview."}]}"#.utf8))
    store.install(session)
    store.streaming = true
    _ = store.run.apply(.token("Checking the next item…"), sequence: 1)
    _ = store.run.apply(.toolStarted(displayTool("live-only")), sequence: 2)
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch/tool-display-render-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func capture<V: View>(_ view: V, name: String, size: NSSize) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
    for mode in ToolDisplayMode.allCases {
        defaults.set(mode.rawValue, forKey: ToolDisplayMode.key)
        try capture(ConversationView(store: store), name: mode.rawValue, size: NSSize(width: 900, height: 850))
    }
    defaults.set(ToolDisplayMode.whileExecuting.rawValue, forKey: ToolDisplayMode.key)
    _ = store.run.apply(.token("\nThe visible reply collapses live details."), sequence: 3)
    try capture(ConversationView(store: store), name: "whileExecuting-reply", size: NSSize(width: 900, height: 850))
    _ = store.run.apply(.toolStarted(displayTool("next-live-tool")), sequence: 4)
    try capture(ConversationView(store: store), name: "whileExecuting-newtool", size: NSSize(width: 900, height: 850))
    try capture(ToolDisplaySettingsView().padding(24), name: "settings", size: NSSize(width: 550, height: 210))
    #expect(store.api == nil)
    print("TOOL DISPLAY RENDER: \(directory.path)")
}

