import Foundation

/// Client-only routing. Run IDs follow api/route_session_list_cache.py's
/// cron_{exact job ID}_{YYYYMMDD_HHMMSS} contract, not task display names.
struct CronSessionRouting {
    private static let runExpression = try! NSRegularExpression(pattern: #"\Acron_(.+)_[0-9]{8}_[0-9]{6}\z"#)

    static func jobID(fromRunID id: String) -> String? {
        let range = NSRange(id.startIndex..., in: id)
        guard let match = runExpression.firstMatch(in: id, range: range),
              let jobRange = Range(match.range(at: 1), in: id) else { return nil }
        return String(id[jobRange])
    }

    let conversations: [SessionSummary]
    private let sessions: [SessionSummary]
    private struct Run {
        let id: String
        var profiles: Set<String>
    }
    private let runByWorker: [String: Run]

    func workers(for job: CronJob) -> [SessionSummary] {
        guard let id = job.jobId else { return [] }
        return sessions.filter { session in
            guard let run = runByWorker[session.id], Self.jobID(fromRunID: run.id) == id else { return false }
            // Unknown profiles are not evidence of conflict; reported profiles
            // must agree along the entire delegated path, including the run.
            var profiles = run.profiles
            if let profile = job.profile { profiles.insert(profile) }
            return profiles.count <= 1
        }
    }

    init(sessions: [SessionSummary], relationshipSnapshot: [SessionSummary] = []) {
        var seen: Set<String> = []
        let unique = sessions.filter { seen.insert($0.id).inserted }
        // Partial/current results are authoritative for IDs they actually report.
        let lookup = unique + relationshipSnapshot.filter { seen.insert($0.id).inserted }
        let byID = Dictionary(lookup.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: Run] = [:]
        // Memoize the single-parent walk. Cycle detection and first-occurrence
        // deduplication keep malformed graphs finite without inventing owners.
        var completed: Set<String> = []
        for session in unique {
            var path: [String] = []
            var visiting: Set<String> = []
            var current = session.id
            var run: Run?
            while !completed.contains(current), let node = byID[current],
                  SessionHierarchy.isSubagent(node), visiting.insert(current).inserted {
                path.append(current)
                guard let parent = node.parentSessionId, parent != current else { break }
                let parentSources = byID[parent].map { [$0.rawSource, $0.sourceTag, $0.sessionSource].compactMap { $0?.lowercased() } } ?? []
                if Self.jobID(fromRunID: parent) != nil || parentSources.contains("cron") {
                    run = Run(id: parent, profiles: Set([byID[parent]?.profile].compactMap { $0 }))
                    break
                }
                current = parent
            }
            run = run ?? resolved[current]
            for id in path.reversed() {
                if let profile = byID[id]?.profile { run?.profiles.insert(profile) }
                if let run { resolved[id] = run }
                completed.insert(id)
            }
        }
        self.sessions = unique
        runByWorker = resolved
        conversations = unique.filter { resolved[$0.id] == nil }
    }
}
