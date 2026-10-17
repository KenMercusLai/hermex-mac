import Foundation

struct SSEFrame {
    var type: String
    var data: String
    var id: String?
    var sequence: Int? { id.flatMap { Int($0.split(separator: ":").last ?? "") } }
}
struct SSEFrameParser {
    private var type = "message"
    private var parts: [String] = []
    private var id: String?
    mutating func line(_ line: String) -> SSEFrame? {
        if line.isEmpty {
            defer { type = "message"; parts = []; id = nil }
            guard !parts.isEmpty else { return nil }
            return SSEFrame(type: type, data: parts.joined(separator: "\n"), id: id)
        }
        if line.hasPrefix(":") { return nil }
        let split = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = split.count > 1 ? String(split[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch split.first {
        case "event": type = value
        case "data": parts.append(value)
        case "id": if !value.contains("\0") { id = value }
        default: break
        }
        return nil
    }
}

enum MacStream {
    /// Uses the exact APIClient session (private cookie jar) and redirect guard.
    static func consume(client: APIClient, streamID: String, after: Int?,
                        onFrame: @escaping @MainActor (SSEFrame, SSEEvent) -> Bool) async throws {
        var request = URLRequest(url: client.chatStreamURL(streamID: streamID, replayAfterSeq: after))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-transform", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 120
        let session = client.session
        let (bytes, response) = try await session.bytes(for: request, delegate: client.redirectHeaderStripper)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MacFailure.message("Stream connection was refused. Reconnect or sign in again.")
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
            throw MacFailure.message("The server returned a non-SSE response. Check the endpoint or reverse proxy.")
        }
        var parser = SSEFrameParser()
        // AsyncBytes.lines omits blank lines on Foundation: SSE needs them as frame
        // boundaries, so split UTF-8 bytes ourselves without splitting Unicode scalars.
        var lineBytes = Data()
        for try await byte in bytes {
            if byte == 10 {
                try Task.checkCancellation()
                if lineBytes.last == 13 { lineBytes.removeLast() }
                let line = String(decoding: lineBytes, as: UTF8.self)
                lineBytes.removeAll(keepingCapacity: true)
                if let frame = parser.line(line) {
                    if await onFrame(frame, SSEEventDecoder.decode(eventType: frame.type, data: frame.data)) { return }
                }
            } else {
                guard lineBytes.count < 2 * 1024 * 1024 else { throw MacFailure.message("SSE line exceeded the 2 MB safety limit.") }
                lineBytes.append(byte)
            }
        }
        throw MacFailure.message("Stream disconnected before completion. Reattach resumes this run without resending your message.")
    }
}
