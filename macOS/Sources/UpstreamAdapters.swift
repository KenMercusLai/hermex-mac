// Platform-independent excerpts from upstream MIT-licensed sources.
// APIClient+Memory.swift: webui read only (direct-Hermes stack not linked).
// BotArtifactDownload.swift / BotArtifact.swift: bounded preview buffer.
import Foundation

// Needed by the preserved endpoint models; Kanban UI is not linked on Mac.
enum KanbanBackend: Sendable { case webui, hermes }

extension APIClient {
    func memory() async throws -> MemoryResponse {
        try await send(endpoint: .memory, method: "GET")
    }
}

struct BotArtifactBuffer {
    static let maximumBytes = 25 * 1024 * 1024
    let limit: Int
    private(set) var data = Data()
    init(limit: Int = maximumBytes) { self.limit = limit }
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw BotArtifactFailure.tooLarge }
        data.append(chunk)
    }
}
enum BotArtifactFailure: Error, LocalizedError {
    case tooLarge
    var errorDescription: String? { "File exceeds the 25 MB preview limit." }
}
