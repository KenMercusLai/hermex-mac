import Foundation

/// Presentation only: producer source metadata proves delegation, not a title or
/// a parent link (which the server also uses for cron, forks and compression).
struct SessionHierarchy {
    struct Row: Identifiable {
        let session: SessionSummary
        let depth: Int
        let descendantCount: Int
        let activeDescendantCount: Int
        let context: String?
        let containsSelectedDescendant: Bool
        var id: String { session.id }
    }
    let sessions: [SessionSummary]
    private let byID: [String: SessionSummary]
    private let parents: [String: String]
    private let children: [String: [String]]
    private let invalidParents: Set<String>

    static func isActive(_ session: SessionSummary) -> Bool {
        session.isStreaming == true || session.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || session.hasPendingUserMessage == true
    }

    static func isSubagent(_ session: SessionSummary) -> Bool {
        let sources = [session.rawSource, session.sourceTag, session.sessionSource].compactMap { $0?.lowercased() }
        let excluded = ["fork", "continuation", "compression", "compression_continuation", "context_compression"]
        guard !sources.contains(where: { excluded.contains($0) }),
              !excluded.contains(session.relationshipType?.lowercased() ?? "") else { return false }
        return sources.contains("subagent")
    }

    init(sessions: [SessionSummary]) {
        var seen: Set<String> = []
        self.sessions = sessions.filter { seen.insert($0.id).inserted }
        let byID = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byID = byID
        var parents: [String: String] = [:]
        for session in self.sessions where Self.isSubagent(session) {
            // Never trim an identifier into a relationship with a different row.
            if let parent = session.parentSessionId, !parent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               byID[parent] != nil { parents[session.id] = parent }
        }
        // Each node has at most one parent. Cut every edge within a cycle rather
        // than inventing a preferred owner. Walk iteratively, including self-links.
        var visited: Set<String> = []
        var invalid: Set<String> = []
        for session in self.sessions where !visited.contains(session.id) {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var current: String? = session.id
            while let id = current, !visited.contains(id) {
                if let start = positions[id] {
                    for member in path[start...] { invalid.insert(member); parents.removeValue(forKey: member) }
                    break
                }
                positions[id] = path.count
                path.append(id)
                current = parents[id]
            }
            visited.formUnion(path)
        }
        self.parents = parents
        invalidParents = invalid
        var children: [String: [String]] = [:]
        for session in self.sessions {
            if let parent = parents[session.id] { children[parent, default: []].append(session.id) }
        }
        self.children = children
    }

    private func context(for session: SessionSummary) -> String? {
        guard Self.isSubagent(session) else { return nil }
        guard let parent = session.parentSessionId, !parent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Subagent · Parent not reported"
        }
        if invalidParents.contains(session.id) { return "Subagent · Invalid parent link: \(parent)" }
        guard let owner = byID[parent] else { return "Subagent · Parent not in list: \(parent)" }
        return "Subagent · Parent: \(owner.title ?? parent)"
    }

    func ancestors(of id: String?) -> Set<String> {
        var result: Set<String> = []
        var current = id.flatMap { parents[$0] }
        while let parent = current, result.insert(parent).inserted { current = parents[parent] }
        return result
    }

    func rows(expanded: Set<String>, searching: Bool = false, selectedID: String? = nil) -> [Row] {
        let selectedAncestors = ancestors(of: selectedID)
        if searching {
            return sessions.map { Row(session: $0, depth: 0, descendantCount: 0, activeDescendantCount: 0, context: context(for: $0), containsSelectedDescendant: false) }
        }
        let roots = sessions.filter { parents[$0.id] == nil }.map(\.id)
        // Preorder followed in reverse gives a bottom-up count without recursion
        // or an O(n²) descendant walk for each rendered row.
        var order: [(id: String, depth: Int)] = []
        var stack = roots.reversed().map { (id: $0, depth: 0) }
        while let node = stack.popLast() {
            order.append(node)
            for child in (children[node.id] ?? []).reversed() { stack.append((child, node.depth + 1)) }
        }
        var counts: [String: Int] = [:]
        var active: [String: Int] = [:]
        for node in order.reversed() {
            if let parent = parents[node.id] {
                counts[parent, default: 0] += 1 + counts[node.id, default: 0]
                active[parent, default: 0] += (byID[node.id].map(Self.isActive) == true ? 1 : 0) + active[node.id, default: 0]
            }
        }
        var visible: Set<String> = []
        return order.compactMap { node in
            if let parent = parents[node.id], !(visible.contains(parent) && expanded.contains(parent)) { return nil }
            visible.insert(node.id)
            guard let session = byID[node.id] else { return nil }
            return Row(session: session, depth: node.depth, descendantCount: counts[node.id, default: 0],
                       activeDescendantCount: active[node.id, default: 0], context: context(for: session),
                       containsSelectedDescendant: selectedAncestors.contains(node.id))
        }
    }
}

/// In-memory IDs only. Search payloads are partial and must not prune expansion.
struct SessionDisclosureState {
    private(set) var expanded: Set<String> = []
    private var scope: String?
    private var selectedID: String?
    private var selectedAncestors: Set<String> = []

    mutating func toggle(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
    }

    mutating func reconcile(scope: String?, hierarchy: SessionHierarchy, selectedID: String?, searching: Bool = false) {
        if self.scope != scope || scope == nil {
            expanded = []
            selectedAncestors = []
            self.selectedID = nil
            self.scope = scope
        }
        guard scope != nil, !searching else { return }
        expanded.formIntersection(hierarchy.sessions.map(\.id))
        let ancestors = hierarchy.ancestors(of: selectedID)
        if self.selectedID != selectedID || !ancestors.subtracting(selectedAncestors).isEmpty {
            expanded.formUnion(ancestors)
        }
        self.selectedID = selectedID
        selectedAncestors = ancestors
    }
}
