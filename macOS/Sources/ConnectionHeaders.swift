import Foundation

/// Mac-only strict editor policy on the original portable CustomHeader model.
/// Blank values are placeholders; duplicate names use the last nonblank row.
enum ConnectionHeaders {
    static let clientID = "CF-Access-Client-Id"
    static let clientSecret = "CF-Access-Client-Secret"
    static var placeholders: [CustomHeader] { [CustomHeader(name: clientID), CustomHeader(name: clientSecret)] }
    // Transport-managed fields cannot safely be user supplied. Accept/Content-Type
    // remain allowed: the upstream request builders always set their built-ins last.
    private static let reserved: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "cookie", "set-cookie", "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer"]

    static func validated(_ rows: [CustomHeader]) throws -> [CustomHeader] {
        var result: [CustomHeader] = []
        for (index, row) in rows.enumerated() {
            guard !row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if row.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    throw MacFailure.message("Header row \(index + 1): values must not contain control characters.")
                }
                continue
            }
            guard row.isApplicable, !row.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MacFailure.message("Header row \(index + 1): enter a valid HTTP header name (letters, digits or token punctuation; no spaces or colon).")
            }
            guard !row.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MacFailure.message("Header row \(index + 1): values must not contain control characters.")
            }
            let name = row.sanitizedName
            guard !reserved.contains(name.lowercased()) else {
                throw MacFailure.message("Header row \(index + 1): this transport-managed header cannot be overridden.")
            }
            result.removeAll { $0.sanitizedName.caseInsensitiveCompare(name) == .orderedSame }
            result.append(CustomHeader(name: name, value: row.sanitizedValue))
        }
        let hasID = result.contains { $0.name.caseInsensitiveCompare(clientID) == .orderedSame }
        let hasSecret = result.contains { $0.name.caseInsensitiveCompare(clientSecret) == .orderedSame }
        guard hasID == hasSecret else {
            throw MacFailure.message("Cloudflare Access needs both CF-Access-Client-Id and CF-Access-Client-Secret. Fill in both Service Token values, or clear both for a server without Access. This is separate from the WebUI password.")
        }
        return result
    }
}

struct ConnectionHeaderVault {
    let vault: MacKeychain
    private func account(_ address: URL) -> String { "connection-headers|" + address.absoluteString }
    func load(for address: URL) throws -> [CustomHeader] {
        guard let data = try vault.read(account: account(address)) else { return [] }
        return try ConnectionHeaders.validated(JSONDecoder().decode([CustomHeader].self, from: data))
    }
    func save(_ headers: [CustomHeader], for address: URL) throws {
        let snapshot = try ConnectionHeaders.validated(headers)
        if snapshot.isEmpty { try clear(for: address) }
        else { try vault.save(JSONEncoder().encode(snapshot), account: account(address)) }
    }
    func clear(for address: URL) throws { try vault.delete(account: account(address)) }
}
