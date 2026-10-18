import Foundation

enum MediaDownloadFailure: LocalizedError {
    case status(Int), network
    var errorDescription: String? {
        switch self {
        case .status(401): return "Download requires sign-in. Reconnect to the server and try again."
        case .status(403): return "Download denied by the server or authenticated proxy. Check file permissions and connection access."
        case .status(404): return "The download is no longer available on the server."
        case .status(let code): return "Download failed (HTTP \(code)). Cross-origin redirects are not followed."
        case .network: return "The download was interrupted. The existing destination was not changed."
        }
    }
}

/// Downloads fail closed on cross-origin redirects, including cookie-bearing
/// same-host/different-port hops. The existing immutable per-client redirect
/// stripper remains installed for all allowed same-origin hops.
final class MediaDownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let stripper: CrossOriginHeaderStripper
    init(origin: URL, stripper: CrossOriginHeaderStripper) { self.origin = origin; self.stripper = stripper }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.user == nil, target.password == nil,
              APIClient.isSameOrigin(target, as: origin) else { completionHandler(nil); return }
        stripper.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}

extension APIClient {
    /// URLSession's download task spools to disk; large archives never become Data.
    /// Only call after destination confirmation, with the captured owner's headers.
    func downloadMedia(reference: MediaReference, sessionID: String, headers: [CustomHeader]) async throws -> URL {
        let plan = MediaDownloadPlan(baseURL: baseURL, reference: reference, sessionID: sessionID, headers: headers)
        let transport = plan.authenticated ? session : publicMediaSession
        let guardDelegate = MediaDownloadRedirectGuard(origin: plan.request.url!, stripper: redirectHeaderStripper)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await transport.download(for: plan.request, delegate: guardDelegate) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MediaDownloadFailure.network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw MediaDownloadFailure.status((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if Task.isCancelled { try? FileManager.default.removeItem(at: temporary); throw CancellationError() }
        return temporary
    }
}


struct MediaDownloadPlan {
    let request: URLRequest
    let authenticated: Bool
    init(baseURL: URL, reference: MediaReference, sessionID: String, headers: [CustomHeader]) {
        var url = reference.remoteURL ?? Endpoint.media(sessionID: sessionID, path: reference.source).url(relativeTo: baseURL)
        if reference.remoteURL == nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // URLQueryItem leaves '+' literal, but Python parse_qs treats it as a
            // space. Escape only the encoded query's plus signs, not opaque input.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            url = components.url ?? url
        }
        authenticated = APIClient.isSameOrigin(url, as: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = authenticated
        if authenticated { headers.apply(to: &request) }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        self.request = request
    }
}
