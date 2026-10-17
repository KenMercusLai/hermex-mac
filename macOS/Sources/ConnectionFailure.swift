import Foundation

/// Never display response bodies or request URLs in transport errors: either can
/// contain credentials echoed by an untrusted proxy/server.
enum ConnectionFailure {
    static let accessHelp = "Cloudflare Access blocked the connection before WebUI sign-in. In Connection Headers, enter both Service Token values (CF-Access-Client-Id and CF-Access-Client-Secret). The Access application must allow that token in a Service Auth policy. This is separate from the WebUI password; browser email/SSO sign-in is not supported."

    static func httpMessage(response: HTTPURLResponse, data: Data) -> String? {
        let html = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
        let cloudflare = response.value(forHTTPHeaderField: "Server")?.lowercased().contains("cloudflare") == true
        let finalURL = response.url
        let location = response.value(forHTTPHeaderField: "Location")?.lowercased() ?? ""
        let login = finalURL?.host?.lowercased().hasSuffix(".cloudflareaccess.com") == true || finalURL?.path.hasPrefix("/cdn-cgi/access/") == true || location.contains(".cloudflareaccess.com/") || location.contains("/cdn-cgi/access/")
        if login || (response.statusCode == 403 && html && cloudflare) { return accessHelp }
        if !(200..<300).contains(response.statusCode) {
            return APIError.http(statusCode: response.statusCode, body: nil).localizedDescription
        }
        if html { return "The server returned an HTML page instead of the WebUI API. Check the server URL and reverse-proxy authentication. Cloudflare Access requires a Service Token and a Service Auth policy, not the WebUI password." }
        return nil
    }

    static func message(_ error: Error, headers: [CustomHeader] = [], secrets: [String] = []) -> String {
        let text: String
        switch error {
        case APIError.http(let code, let body):
            let lower = body?.lowercased() ?? ""
            if lower.contains("/cdn-cgi/access/") || lower.contains("cloudflare access") { text = accessHelp }
            else { text = APIError.http(statusCode: code, body: nil).localizedDescription }
        case APIError.network:
            text = "The connection failed. Check the server address, network and TLS certificate, then reconnect."
        case APIError.decoding:
            text = "The server did not return the expected WebUI API response. Check the server URL and reverse-proxy authentication."
        default: text = error.localizedDescription
        }
        return (headers.map(\.sanitizedValue) + secrets).filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }

    static func health(client: APIClient, url: URL, session: URLSession, headers: [CustomHeader]) async throws {
        var request = URLRequest(url: Endpoint.health.url(relativeTo: url))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        headers.apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: client.redirectHeaderStripper)
        guard let response = response as? HTTPURLResponse else { throw MacFailure.message("The server did not return an HTTP response.") }
        if let message = httpMessage(response: response, data: data) { throw MacFailure.message(message) }
        let _: HealthResponse = try await client.decode(HealthResponse.self, from: data)
    }
}
