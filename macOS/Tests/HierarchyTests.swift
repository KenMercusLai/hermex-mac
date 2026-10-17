import Testing
import Foundation
@testable import HermexMac

private func hierarchySession(_ id: String, parent: String? = nil, source: String? = nil,
                              relationship: String? = nil, active: Bool = false) -> SessionSummary {
    SessionSummary(sessionId: id, title: "Subagent Session", isStreaming: active,
                   rawSource: source, parentSessionId: parent, relationshipType: relationship)
}

@Test func delegatedMetadataGroupsChildrenWithoutGuessingTitlesOrParentLinks() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let wire = Data(#"[{"session_id":"child","title":"Worker","source_tag":"subagent","raw_source":"subagent","session_source":"subagent","parent_session_id":"parent","relationship_type":"child_session","read_only":true},{"session_id":"parent","title":"Owner"}]"#.utf8)
    let sessions = try decoder.decode([SessionSummary].self, from: wire)
    #expect(sessions[0].parentSessionId == "parent")
    #expect(sessions[0].readOnly == true)
    let hierarchy = SessionHierarchy(sessions: sessions + [
        hierarchySession("title-only", parent: "parent"),
        hierarchySession("cron", parent: "parent", source: "cron", relationship: "child_session"),
        hierarchySession("fork", parent: "parent", source: "subagent", relationship: "fork"),
        hierarchySession("continuation", parent: "parent", source: "subagent", relationship: "continuation")
    ])
    #expect(hierarchy.rows(expanded: []).map(\.id) == ["parent", "title-only", "cron", "fork", "continuation"])
    let rows = hierarchy.rows(expanded: ["parent"])
    #expect(rows.map(\.id) == ["parent", "child", "title-only", "cron", "fork", "continuation"])
    #expect(rows[0].descendantCount == 1)
    #expect(rows[1].depth == 1)
    #expect(rows[1].session.readOnly == true)
}

@Test func nestedBranchesPreserveInputOrderingAndBubbleActiveDescendants() {
    let hierarchy = SessionHierarchy(sessions: [
        hierarchySession("grandchild", parent: "child", source: "subagent", active: true),
        hierarchySession("sibling", parent: "parent", source: "subagent"),
        hierarchySession("other"), hierarchySession("parent"),
        hierarchySession("child", parent: "parent", source: "subagent")
    ])
    let rows = hierarchy.rows(expanded: ["parent", "child"])
    #expect(rows.map(\.id) == ["other", "parent", "sibling", "child", "grandchild"])
    #expect(rows.map(\.depth) == [0, 0, 1, 1, 2])
    #expect(rows.map(\.descendantCount) == [0, 3, 0, 1, 0])
    #expect(rows.map(\.activeDescendantCount) == [0, 1, 0, 1, 0])
    #expect(hierarchy.rows(expanded: ["parent"]).map(\.id) == ["other", "parent", "sibling", "child"])
}

@Test func malformedRelationshipsRemainVisibleExactlyOnceWithoutInventedParents() throws {
    let input = [
        hierarchySession("a", parent: "b", source: "subagent"),
        hierarchySession("b", parent: "a", source: "subagent"),
        hierarchySession("self", parent: "self", source: "subagent"),
        hierarchySession("orphan", parent: "missing", source: "subagent"),
        hierarchySession("unknown", source: "subagent"),
        hierarchySession("literal", parent: " parent ", source: "subagent"),
        hierarchySession("parent"), hierarchySession("parent")
    ]
    let rows = SessionHierarchy(sessions: input).rows(expanded: Set(input.map(\.id)))
    #expect(rows.map(\.id) == ["a", "b", "self", "orphan", "unknown", "literal", "parent"])
    #expect(rows.allSatisfy { $0.depth == 0 })
    try #require(rows.count == 7)
    #expect(rows[0].context?.contains("Invalid parent link") == true)
    #expect(rows[3].context?.contains("Parent not in list: missing") == true)
    #expect(rows[4].context?.contains("Parent not reported") == true)
    #expect(rows[5].context?.hasSuffix(" parent ") == true)
}

@Test func searchReturnsEveryMatchFlatWithTruthfulParentContext() {
    let parent = SessionSummary(sessionId: "parent", title: "Owner")
    let child = hierarchySession("child", parent: "parent", source: "subagent")
    let grandchild = hierarchySession("grandchild", parent: "child", source: "subagent")
    let rows = SessionHierarchy(sessions: [grandchild, parent, child]).rows(expanded: [], searching: true)
    #expect(rows.map(\.id) == ["grandchild", "parent", "child"])
    #expect(rows.allSatisfy { $0.depth == 0 })
    #expect(rows.last?.context == "Subagent · Parent: Owner")
    let onlyMatch = SessionHierarchy(sessions: [grandchild]).rows(expanded: [], searching: true)
    #expect(onlyMatch.map(\.id) == ["grandchild"])
    #expect(onlyMatch.first?.context == "Subagent · Parent not in list: child")
}

@Test func disclosureSurvivesRefreshButNotDisconnectOrServerChange() {
    let input = [hierarchySession("parent"), hierarchySession("child", parent: "parent", source: "subagent")]
    var state = SessionDisclosureState()
    let hierarchy = SessionHierarchy(sessions: input)
    state.reconcile(scope: "https://a.invalid", hierarchy: hierarchy, selectedID: nil)
    #expect(state.expanded.isEmpty)
    state.toggle("parent")
    state.reconcile(scope: "https://a.invalid", hierarchy: SessionHierarchy(sessions: input.reversed()), selectedID: nil)
    #expect(state.expanded == ["parent"])
    // Search is a partial result set, not evidence that a parent was removed.
    state.reconcile(scope: "https://a.invalid", hierarchy: SessionHierarchy(sessions: [input[1]]), selectedID: nil, searching: true)
    #expect(state.expanded == ["parent"])
    state.reconcile(scope: "https://a.invalid", hierarchy: SessionHierarchy(sessions: [input[1]]), selectedID: nil)
    #expect(state.expanded.isEmpty)
    state.toggle("child")
    state.reconcile(scope: "https://b.invalid", hierarchy: hierarchy, selectedID: nil)
    #expect(state.expanded.isEmpty)
    state.toggle("parent")
    state.reconcile(scope: nil, hierarchy: hierarchy, selectedID: nil)
    #expect(state.expanded.isEmpty)
}

@Test func selectedChildRevealsNewAncestorsButExplicitCollapseSurvivesRefresh() {
    let parent = hierarchySession("parent")
    let child = hierarchySession("child", parent: "parent", source: "subagent")
    let full = SessionHierarchy(sessions: [child, parent])
    var state = SessionDisclosureState()
    state.reconcile(scope: "https://a.invalid", hierarchy: SessionHierarchy(sessions: [child]), selectedID: "child")
    #expect(state.expanded.isEmpty)
    // Loading its previously missing owner must not hide the selected row.
    state.reconcile(scope: "https://a.invalid", hierarchy: full, selectedID: "child")
    #expect(state.expanded == ["parent"])
    state.toggle("parent")
    state.reconcile(scope: "https://a.invalid", hierarchy: full, selectedID: "child")
    #expect(state.expanded.isEmpty)
    let collapsed = full.rows(expanded: state.expanded, selectedID: "child")
    #expect(collapsed.map(\.id) == ["parent"])
    #expect(collapsed.first?.containsSelectedDescendant == true)
    let root = hierarchySession("root")
    let movedParent = hierarchySession("parent", parent: "root", source: "subagent")
    state.reconcile(scope: "https://a.invalid", hierarchy: SessionHierarchy(sessions: [child, movedParent, root]), selectedID: "child")
    // A new ancestor opens the complete path, including an explicitly collapsed
    // old ancestor, because this is a real ownership change rather than refresh.
    #expect(state.expanded == ["parent", "root"])
}

@Test func sourceAlternativesAndReportedRunFieldsIdentifyActiveWorkers() {
    let sessions = [
        hierarchySession("parent"),
        SessionSummary(sessionId: "tag", activeStreamId: "stream", sourceTag: "subagent", parentSessionId: "parent"),
        SessionSummary(sessionId: "source", hasPendingUserMessage: true, sessionSource: "subagent", parentSessionId: "parent"),
        SessionSummary(sessionId: "label", sourceLabel: "Subagent", parentSessionId: "parent"),
        SessionSummary(sessionId: "compression", rawSource: "subagent", sessionSource: "compression", parentSessionId: "parent")
    ]
    let rows = SessionHierarchy(sessions: sessions).rows(expanded: [])
    #expect(rows.map(\.id) == ["parent", "label", "compression"])
    #expect(rows.first?.descendantCount == 2)
    #expect(rows.first?.activeDescendantCount == 2)
}

@Test func deepHierarchiesUseIterativeTraversalAndKeepEveryIdentity() {
    let count = 4096
    let sessions = (0..<count).map { index in
        hierarchySession("node-\(index)", parent: index == 0 ? nil : "node-\(index - 1)", source: index == 0 ? nil : "subagent")
    }
    let hierarchy = SessionHierarchy(sessions: sessions.reversed())
    let rows = hierarchy.rows(expanded: Set(sessions.map(\.id)), selectedID: "node-4095")
    #expect(rows.count == count)
    #expect(Set(rows.map(\.id)).count == count)
    #expect(rows.last?.depth == 4095)
    #expect(rows.first?.descendantCount == 4095)
    #expect(hierarchy.ancestors(of: "node-4095").count == 4095)
    #expect(hierarchy.rows(expanded: []).map(\.id) == ["node-0"])
}

@Test func duplicateRowsKeepFirstMetadataAndLiteralParentIDs() {
    let first = SessionSummary(sessionId: "child", title: "First", sourceTag: "subagent", parentSessionId: " parent ")
    let duplicate = SessionSummary(sessionId: "child", title: "Ignored", sourceTag: "subagent", parentSessionId: "parent")
    let rows = SessionHierarchy(sessions: [first, duplicate, hierarchySession("parent"), hierarchySession(" parent ")])
        .rows(expanded: ["parent", " parent "])
    #expect(rows.map(\.id) == ["parent", " parent ", "child"])
    #expect(rows.last?.session.title == "First")
    #expect(rows.last?.depth == 1)
}

private final class HierarchyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: String
        switch request.url!.path {
        case "/health": payload = #"{"status":"ok"}"#
        case "/api/auth/status": payload = #"{"auth_enabled":false,"logged_in":true}"#
        case "/api/sessions": payload = #"{"sessions":[{"session_id":"parent","title":"Owner"},{"session_id":"child","title":"Worker","source_tag":"subagent","parent_session_id":"parent","read_only":true}]}"#
        case "/api/session": payload = #"{"session":{"session_id":"child","title":"Worker","read_only":true,"messages":[{"role":"assistant","content":"Worker history"}]}}"#
        default: payload = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func sidebarStoreDisclosureIsSeparateFromReadOnlyChildSelectionAndServerScope() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HierarchyProtocol.self]
    let store = MacStore(persistence: false, sessionFactory: { URLSession(configuration: config) })
    await store.connect(address: "https://a.invalid", password: "", remember: false)
    #expect(store.sidebarRows.map(\.id) == ["parent"])
    store.toggleSessionDisclosure("parent")
    #expect(store.selectedID == nil)
    #expect(store.sidebarRows.map(\.id) == ["parent", "child"])
    await store.selectSession("child")
    #expect(store.messages.first?.content == "Worker history")
    #expect(store.detail?.readOnly == true)
    store.toggleSessionDisclosure("parent")
    #expect(store.selectedID == "child")
    #expect(store.sidebarRows.first?.containsSelectedDescendant == true)
    await store.refresh()
    #expect(store.expandedSessionIDs.isEmpty)
    store.draft = "Must not send"
    await store.send()
    #expect(store.error?.contains("read-only") == true)
    store.toggleSessionDisclosure("parent")
    store.disconnect()
    #expect(store.expandedSessionIDs.isEmpty)
    await store.connect(address: "https://b.invalid", password: "", remember: false)
    #expect(store.sidebarRows.map(\.id) == ["parent"])
    store.disconnect()
}
