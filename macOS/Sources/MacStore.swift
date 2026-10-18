import Foundation
import SwiftUI

struct SavedServer: Codable, Identifiable, Equatable {
    var id: String { address }
    var address: String
    var label: String
}
struct SavedConnections: Codable {
    var servers: [SavedServer]
    var last: String
}
struct ConnectionRegistry {
    let vault: MacKeychain
    func save(servers: [SavedServer], last: String) throws {
        try vault.save(JSONEncoder().encode(SavedConnections(servers: servers, last: last)), account: "connections")
    }
    func load() throws -> SavedConnections? {
        guard let data = try vault.read(account: "connections") else { return nil }
        return try JSONDecoder().decode(SavedConnections.self, from: data)
    }
}

struct SessionDraft {
    var text = ""
    var attachments: [PendingAttachment] = []
}

@MainActor final class MacStore: ObservableObject {
    @Published private(set) var activeMediaDownloads = 0
    private var mediaTransfers: [UUID: Task<URL, Error>] = [:]
    private var publicMediaTransport: URLSession?
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var connectionLabel = "Not connected"
    @Published var servers: [SavedServer] = []
    @Published var address = "http://127.0.0.1:8787" {
        didSet { if oldValue != address { changeHeaderScope() } }
    }
    @Published var connectionHeaders = ConnectionHeaders.placeholders
    private var headerDraftOwner: String?
    private var headerDrafts: [String: [CustomHeader]] = [:]
    private var connectedHeaders: [CustomHeader] = []
    @Published var sessions: [SessionSummary] = [] {
        didSet { reconcileSessionDisclosure() }
    }
    @Published private var sessionDisclosure = SessionDisclosureState()
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID {
                mediaTransfers.values.forEach { $0.cancel() }
                reconcileSessionDisclosure()
            }
        }
    }
    @Published var detail: SessionDetail?
    @Published var messages: [ChatMessage] = []
    @Published var search = ""
    @Published var showArchived = false
    @Published var model = ""
    @Published var provider = ""
    @Published var profile = ""
    @Published var workspace = ""
    @Published var modelCatalog: [ModelCatalogGroup] = []
    @Published var providers: [ProviderSummary] = []
    @Published var profiles: [ProfileSummary] = []
    @Published var workspaces: [WorkspaceRoot] = []
    @Published var draft = ""
    @Published var attachments: [PendingAttachment] = []
    @Published var run = RunProjection()
    @Published var streaming = false
    @Published var streamDisconnected = false
    @Published var streamID: String?
    @Published var panel = "Chat"

    var api: APIClient?
    private var transport: URLSession?
    private let persistence: Bool
    private let sessionFactory: () -> URLSession
    private let vault: MacKeychain
    private var generation = 0
    private var selectionGeneration = 0
    private var streamTask: Task<Void, Never>?
    private var drafts: [String: SessionDraft] = [:]
    private var connectedAddress: String?
    private var scope: String { "\(connectedAddress ?? address)|\(selectedID ?? "new")" }

    // Every async result belongs to the connection and (where relevant) the
    // selection that issued it, including A -> B -> A navigation.
    private struct Ownership {
        let client: APIClient
        let headers: [CustomHeader]
        let address: String
        let connection: Int
        let selection: Int
        let sessionID: String?
    }
    private func ownership() -> Ownership? {
        guard let api, let connectedAddress else { return nil }
        return Ownership(client: api, headers: connectedHeaders, address: connectedAddress, connection: generation,
                         selection: selectionGeneration, sessionID: selectedID)
    }
    private func ownsConnection(_ owner: Ownership) -> Bool {
        generation == owner.connection && api === owner.client && connectedAddress == owner.address
    }
    private func ownsSelection(_ owner: Ownership) -> Bool {
        ownsConnection(owner) && selectionGeneration == owner.selection && selectedID == owner.sessionID
    }


    init(persistence: Bool = true, sessionFactory: @escaping () -> URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config)
    }, vault: MacKeychain = MacKeychain()) {
        self.persistence = persistence
        self.sessionFactory = sessionFactory
        self.vault = vault
        if persistence {
            do {
                if let saved = try ConnectionRegistry(vault: vault).load() { servers = saved.servers; address = saved.last }
            } catch { self.error = errorMessage(error) }
        }
        changeHeaderScope()
    }

    private func headers(for url: URL) throws -> [CustomHeader] {
        if headerDraftOwner == url.absoluteString { return connectionHeaders }
        if let draft = headerDrafts[url.absoluteString] { return draft }
        let saved = persistence ? try ConnectionHeaderVault(vault: vault).load(for: url) : []
        return saved.isEmpty ? ConnectionHeaders.placeholders : saved
    }

    private func changeHeaderScope() {
        if let owner = headerDraftOwner { headerDrafts[owner] = connectionHeaders }
        headerDraftOwner = nil
        connectionHeaders = ConnectionHeaders.placeholders
        guard let url = try? ServerAddress.parse(address) else { return }
        do {
            connectionHeaders = try headers(for: url)
            headerDraftOwner = url.absoluteString
        } catch { self.error = "Saved connection headers could not be loaded. Clear them and re-enter the Service Token." }
    }

    func errorMessage(_ error: Error) -> String {
        ConnectionFailure.message(error, headers: connectedHeaders + connectionHeaders)
    }

    func addCloudflareHeaders() {
        for row in ConnectionHeaders.placeholders where !connectionHeaders.contains(where: { $0.sanitizedName.caseInsensitiveCompare(row.name) == .orderedSame }) {
            connectionHeaders.append(row)
        }
    }

    func clearConnectionHeaders() {
        do {
            let url = try ServerAddress.parse(address)
            if persistence { try ConnectionHeaderVault(vault: vault).clear(for: url) }
            headerDrafts.removeValue(forKey: url.absoluteString)
            connectionHeaders = ConnectionHeaders.placeholders
            headerDraftOwner = url.absoluteString
        } catch { self.error = errorMessage(error) }
    }

    func connect(address raw: String, password enteredPassword: String, remember: Bool, customHeaders: [CustomHeader]? = nil) async {
        guard !busy else { return }
        disconnect()
        let current = generation
        busy = true
        error = nil
        var attemptHeaders: [CustomHeader] = []
        defer { if current == generation { busy = false } }
        do {
            let url = try ServerAddress.parse(raw)
            let connectionAddress = url.absoluteString
            let snapshot = try ConnectionHeaders.validated(customHeaders ?? headers(for: url))
            attemptHeaders = snapshot
            address = connectionAddress
            connectionHeaders = snapshot.isEmpty ? ConnectionHeaders.placeholders : snapshot
            headerDraftOwner = connectionAddress
            if persistence { try ConnectionHeaderVault(vault: vault).save(snapshot, for: url) }
            let session = sessionFactory()
            transport = session
            let publicConfig = URLSessionConfiguration.ephemeral
            publicConfig.httpCookieStorage = nil
            publicConfig.urlCredentialStorage = nil
            publicConfig.httpCookieAcceptPolicy = .never
            publicConfig.httpShouldSetCookies = false
            let publicSession = URLSession(configuration: publicConfig)
            publicMediaTransport = publicSession
            let client = APIClient(baseURL: url, session: session, publicMediaSession: publicSession, customHeaderProvider: { snapshot })
            try await ConnectionFailure.health(client: client, url: url, session: session, headers: snapshot)
            guard current == generation else { return }
            let status = try await client.authStatus()
            guard current == generation else { return }
            if status.authEnabled != false && status.loggedIn != true {
                var password = enteredPassword
                if password.isEmpty, persistence, let data = try vault.read(account: connectionAddress) { password = String(decoding: data, as: UTF8.self) }
                guard !password.isEmpty else { throw MacFailure.message("This server requires a password. Enter its webui password to connect.") }
                let login = try await client.login(password: password)
                guard current == generation else { return }
                guard login.ok == true else { throw MacFailure.message("WebUI password sign-in failed. Check the WebUI password (not the Cloudflare Service Token).") }
                let verified = try await client.authStatus()
                guard current == generation else { return }
                guard verified.loggedIn == true || verified.authEnabled == false else { throw MacFailure.message("The server did not establish an authenticated session.") }
                if remember, persistence { try vault.save(Data(password.utf8), account: connectionAddress) }
                if !remember, persistence { try vault.delete(account: connectionAddress) }
            }
            api = client
            connectedHeaders = snapshot
            connectedAddress = connectionAddress
            address = connectionAddress
            connected = true
            connectionLabel = url.host ?? connectionAddress
            if persistence {
                if !servers.contains(where: { $0.address == connectionAddress }) { servers.append(SavedServer(address: connectionAddress, label: url.host ?? connectionAddress)) }
                try ConnectionRegistry(vault: vault).save(servers: servers, last: connectionAddress)
            }
            try await reloadSessions()
            guard current == generation else { return }
            await loadCatalog()
        } catch {
            guard current == generation else { return }
            self.error = ConnectionFailure.message(error, headers: attemptHeaders, secrets: [enteredPassword])
            connected = false
            connectionLabel = "Connection failed"
        }
    }

    typealias MediaFetcher = (APIClient, MediaReference, String, [CustomHeader]) async throws -> URL
    func saveMedia(_ reference: MediaReference, select: MediaSave.Selector = MediaSave.chooseDestination,
                   fetch: MediaFetcher? = nil) async {
        // Snapshot before the save panel yields. Never recapture credentials or
        // session selection after it returns (including A -> B -> A navigation).
        guard let owner = ownership(), let sessionID = owner.sessionID else { return }
        activeMediaDownloads += 1
        defer { activeMediaDownloads -= 1 }
        do {
            try await MediaSave.perform(reference: reference, select: select, isCurrent: { self.ownsSelection(owner) }, fetch: {
                let id = UUID()
                let transfer = Task {
                    if let fetch { return try await fetch(owner.client, reference, sessionID, owner.headers) }
                    return try await owner.client.downloadMedia(reference: reference, sessionID: sessionID, headers: owner.headers)
                }
                self.mediaTransfers[id] = transfer
                defer { self.mediaTransfers.removeValue(forKey: id) }
                return try await withTaskCancellationHandler(operation: { try await transfer.value }, onCancel: { transfer.cancel() })
            })
        } catch {
            guard ownsSelection(owner) else { return }
            if error is CancellationError { self.error = "Download canceled. The destination was not changed." }
            else if let failure = error as? MediaDownloadFailure { self.error = failure.localizedDescription }
            else { self.error = "The download could not be saved. Check the chosen location and try again." }
        }
    }

    func disconnect() {
        mediaTransfers.values.forEach { $0.cancel() }
        publicMediaTransport?.invalidateAndCancel(); publicMediaTransport = nil
        saveDraft()
        generation += 1
        selectionGeneration += 1
        streamTask?.cancel(); streamTask = nil
        transport?.invalidateAndCancel(); transport = nil
        api = nil
        connectedHeaders = []
        connectedAddress = nil
        busy = false
        error = nil
        connected = false
        connectionLabel = "Not connected"
        sessions = []; selectedID = nil; detail = nil; messages = []
        draft = ""; attachments = []; run = RunProjection()
        streamID = nil; streaming = false; streamDisconnected = false
        providers = []; profiles = []; workspaces = []; modelCatalog = []
        model = ""; provider = ""; profile = ""; workspace = ""; search = ""; panel = "Chat"
    }

    func logout() async {
        guard let owner = ownership() else { return }
        var remoteLogoutUnconfirmed = false
        do {
            let reply = try await owner.client.logout()
            remoteLogoutUnconfirmed = reply.ok != true
        } catch { remoteLogoutUnconfirmed = true }
        guard ownsConnection(owner) else { return }
        // Explicit local sign-out must still forget credentials when the proxy or
        // server is unreachable. Never let an obsolete logout clear another scope.
        do {
            if persistence {
                try vault.delete(account: owner.address)
                try ConnectionHeaderVault(vault: vault).clear(for: ServerAddress.parse(owner.address))
            }
            headerDrafts.removeValue(forKey: owner.address)
            if headerDraftOwner == owner.address { connectionHeaders = ConnectionHeaders.placeholders }
            drafts = drafts.filter { !$0.key.hasPrefix(owner.address + "|") }
            disconnect()
            if remoteLogoutUnconfirmed {
                self.error = "Signed out locally and forgot saved credentials. Server logout could not be confirmed; the remote session may remain valid."
            }
        } catch { self.error = "Could not forget saved credentials: " + errorMessage(error) }
    }

    var isSessionSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var expandedSessionIDs: Set<String> { sessionDisclosure.expanded }
    var sidebarRows: [SessionHierarchy.Row] {
        SessionHierarchy(sessions: sessions).rows(expanded: sessionDisclosure.expanded, searching: isSessionSearch, selectedID: selectedID)
    }
    func toggleSessionDisclosure(_ id: String) { sessionDisclosure.toggle(id) }
    private func reconcileSessionDisclosure() {
        sessionDisclosure.reconcile(scope: connectedAddress, hierarchy: SessionHierarchy(sessions: sessions),
                                    selectedID: selectedID, searching: isSessionSearch)
    }

    func reloadSessions() async throws {
        guard let api else { return }
        let current = generation
        let result: [SessionSummary]
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = try await api.sessions(includeArchived: showArchived, archivedLimit: nil).sessions ?? []
        } else { result = try await api.searchSessions(query: search).sessions ?? [] }
        guard current == generation else { return }
        sessions = result.sorted {
            if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }
            return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0)
        }
    }

    func refresh() async {
        guard let owner = ownership() else { return }
        do { try await reloadSessions() } catch { if ownsConnection(owner) { self.error = errorMessage(error) } }
    }

    func loadCatalog() async {
        guard let owner = ownership() else { return }
        let api = owner.client
        // Optional feature errors are surfaced individually; older servers may lack a panel.
        do {
            let response = try await api.models()
            guard ownsConnection(owner) else { return }
            modelCatalog = response.catalogGroups
            if ownsSelection(owner), model.isEmpty { model = response.defaultModel ?? "" }
            if ownsSelection(owner), provider.isEmpty { provider = response.activeProvider ?? "" }
            let providerResponse = try await api.providers()
            guard ownsConnection(owner) else { return }
            providers = providerResponse.providers ?? []
            let p = try await api.profiles()
            guard ownsConnection(owner) else { return }
            profiles = p.profiles ?? []
            if ownsSelection(owner), profile.isEmpty { profile = p.active ?? "" }
            let w = try await api.workspaces()
            guard ownsConnection(owner) else { return }
            workspaces = w.workspaces ?? []
            if ownsSelection(owner), workspace.isEmpty { workspace = w.last ?? "" }
        } catch { if ownsConnection(owner) { self.error = "Some server controls are unavailable: " + errorMessage(error) } }
    }

    func saveDraft() { if connected { drafts[scope] = SessionDraft(text: draft, attachments: attachments) } }

    func selectSession(_ id: String) async {
        guard let api else { return }
        panel = "Chat"
        guard selectedID != id else { return }
        saveDraft()
        selectionGeneration += 1
        let current = selectionGeneration
        streamTask?.cancel(); streamTask = nil
        streaming = false; streamDisconnected = false; streamID = nil; run = RunProjection()
        selectedID = id; detail = nil; messages = []; panel = "Chat"
        let saved = drafts[scope] ?? SessionDraft()
        draft = saved.text; attachments = saved.attachments
        do {
            let result = try await api.session(id: id, messageLimit: 100, expandRenderable: true)
            guard current == selectionGeneration else { return }
            guard let session = result.session else { throw MacFailure.message("The server did not return a session.") }
            install(session)
        } catch { if current == selectionGeneration { self.error = errorMessage(error) } }
    }

    func install(_ session: SessionDetail) {
        detail = session
        selectedID = session.sessionId
        messages = session.messages ?? []
        workspace = session.workspace ?? workspace
        model = session.model ?? model
        provider = session.modelProvider ?? provider
        profile = session.profile ?? profile
    }

    enum SessionAction {
        case rename(String), pin(Bool), archive(Bool), delete
    }
    func mutate(_ id: String, action: SessionAction) async {
        guard let owner = ownership(), !busy else { return }
        let api = owner.client
        busy = true
        defer { if ownsConnection(owner) { busy = false } }
        do {
            let result: SessionMutationResponse
            switch action {
            case .rename(let name): result = try await api.renameSession(id: id, title: name)
            case .pin(let value): result = try await api.pinSession(id: id, pinned: value)
            case .archive(let value): result = try await api.archiveSession(id: id, archived: value)
            case .delete: result = try await api.deleteSession(id: id)
            }
            guard ownsConnection(owner) else { return }
            guard result.ok != false, result.error == nil else { throw MacFailure.message(result.error ?? "Session action failed.") }
            if case .delete = action, ownsSelection(owner), selectedID == id {
                selectionGeneration += 1
                streamTask?.cancel(); streamTask = nil
                drafts.removeValue(forKey: scope)
                selectedID = nil; detail = nil; messages = []; draft = ""; attachments = []
                streamID = nil; streaming = false; streamDisconnected = false; run = RunProjection()
            }
            try await reloadSessions()
            guard ownsSelection(owner) else { return }
            if selectedID == id {
                let fetched = try await api.session(id: id, messageLimit: 100)
                guard ownsSelection(owner) else { return }
                if let session = fetched.session { install(session) }
            }
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func saveSessionControls() async {
        guard let owner = ownership(), let id = owner.sessionID, !streaming else { return }
        do {
            let response = try await owner.client.updateSession(id: id, workspace: workspace.macNonEmpty, model: model.macNonEmpty, modelProvider: provider.macNonEmpty)
            guard ownsSelection(owner) else { return }
            guard let session = response.session else { throw MacFailure.message("The server did not confirm the session settings.") }
            install(session)
            try await reloadSessions()
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func loadOlder() async {
        guard let owner = ownership(), let id = owner.sessionID, let before = detail?.messagesOffset, before > 0 else { return }
        do {
            let result = try await owner.client.session(id: id, messageLimit: 100, messageBefore: before)
            guard ownsSelection(owner), let session = result.session else { return }
            messages = (session.messages ?? []) + messages
            detail = session
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func upload(_ urls: [URL]) async {
        guard let owner = ownership(), let id = owner.sessionID, !busy else { return }
        busy = true
        defer { if ownsConnection(owner) { busy = false } }
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= PendingAttachment.maximumUploadBytes else { throw MacFailure.message(PendingAttachment.uploadTooLargeMessage(filename: url.lastPathComponent)) }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= PendingAttachment.maximumUploadBytes else { throw MacFailure.message("Attachment exceeds 20 MB.") }
                // Keep multipart dispositions safe even with unusual local filenames.
                let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                let result = try await owner.client.uploadFile(sessionID: id, data: data, filename: filename)
                guard ownsSelection(owner) else { return }
                guard let path = result.path, result.error == nil else { throw MacFailure.message(result.error ?? "Upload did not return a server path.") }
                attachments.append(PendingAttachment(name: result.filename ?? filename, path: path, mime: result.mime ?? "application/octet-stream", size: result.size, isImage: result.isImage == true))
            }
            saveDraft()
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func send() async {
        guard let owner = ownership(), let id = owner.sessionID, !streaming, !busy,
              draft.macNonEmpty != nil || !attachments.isEmpty else { return }
        guard detail?.readOnly != true, detail?.isReadOnly != true else { error = "This external session is read-only. Create a new session to continue."; return }
        busy = true
        error = nil
        defer { if ownsConnection(owner) { busy = false } }
        do {
            let message = PendingAttachment.chatMessageText(draft: draft, attachments: attachments)
            let result = try await owner.client.startChat(sessionID: id, message: message, workspace: workspace.macNonEmpty, model: model.macNonEmpty, modelProvider: provider.macNonEmpty, profile: detail?.profile, explicitModelPick: true, attachments: attachments.isEmpty ? nil : attachments.map { $0.toJSONValue() })
            guard ownsSelection(owner) else { return }
            guard let stream = result.streamId else { throw MacFailure.message(result.error ?? "No stream was returned. Check conversation history before retrying; the request is never automatically resent.") }
            messages.append(ChatMessage(role: "user", content: message, timestamp: Date().timeIntervalSince1970, messageId: nil))
            draft = ""; attachments = []; saveDraft()
            run = RunProjection()
            streamID = stream
            attach(stream, owner: owner)
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) + " Check history before retrying a send; its delivery may be uncertain." } }
    }

    private func attach(_ stream: String, owner: Ownership) {
        guard ownsSelection(owner), let id = owner.sessionID else { return }
        let api = owner.client
        streamTask?.cancel()
        streaming = true; streamDisconnected = false
        let after = run.sequence
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await MacStream.consume(client: api, streamID: stream, after: after, headers: owner.headers) { [weak self] frame, event in
                    guard let self, self.ownsSelection(owner), self.streamID == stream else { return true }
                    return self.run.apply(event, sequence: frame.sequence)
                }
                guard !Task.isCancelled, self.ownsSelection(owner), self.streamID == stream else { return }
                self.streaming = false; self.streamDisconnected = false; self.streamID = nil
                if let failure = self.run.error { self.error = self.errorMessage(MacFailure.message(failure)) }
                let result = try await api.session(id: id, messageLimit: 100, expandRenderable: true)
                guard !Task.isCancelled, self.ownsSelection(owner) else { return }
                if let session = result.session { self.install(session) }
                self.run = RunProjection()
                try await self.reloadSessions()
            } catch {
                guard !Task.isCancelled, self.ownsSelection(owner) else { return }
                self.streamDisconnected = true
                self.error = errorMessage(error)
                // Keep streamID, projection and cursor; reattach NEVER calls startChat.
            }
        }
    }

    func waitForStream() async { await streamTask?.value }

    func reattach() async {
        guard let owner = ownership(), let id = owner.sessionID else { return }
        let api = owner.client
        let expectedStream = streamID
        do {
            if let streamID = expectedStream {
                let status = try await api.chatStreamStatus(streamID: streamID)
                guard ownsSelection(owner), self.streamID == expectedStream else { return }
                if status.active == false && status.replayAvailable != true {
                    let result = try await api.session(id: id, messageLimit: 100)
                    guard ownsSelection(owner), self.streamID == expectedStream else { return }
                    if let session = result.session { install(session) }
                    streaming = false; streamDisconnected = false; self.streamID = nil; run = RunProjection()
                    return
                }
                attach(streamID, owner: owner)
            } else {
                let status = try await api.sessionStatus(id: id)
                guard ownsSelection(owner), streamID == expectedStream else { return }
                if let stream = status.activeStreamId { streamID = stream; run = RunProjection(); attach(stream, owner: owner) }
                else {
                    let result = try await api.session(id: id, messageLimit: 100)
                    guard ownsSelection(owner), streamID == expectedStream else { return }
                    if let session = result.session { install(session) }
                    streaming = false; streamDisconnected = false
                }
            }
            guard ownsSelection(owner) else { return }
            await checkPending()
        } catch { if ownsSelection(owner), streamID == expectedStream { self.error = errorMessage(error) } }
    }

    func stop() async {
        guard let owner = ownership(), let id = owner.sessionID, let streamID else { return }
        do {
            let result = try await owner.client.cancelChat(streamID: streamID)
            guard ownsSelection(owner), self.streamID == streamID else { return }
            guard result.ok != false, result.error == nil else { throw MacFailure.message(result.error ?? "Stop was refused.") }
            streamTask?.cancel(); streamTask = nil
            streaming = false; streamDisconnected = false; self.streamID = nil
            let history = try await owner.client.session(id: id, messageLimit: 100)
            guard ownsSelection(owner), self.streamID == nil else { return }
            if let session = history.session { install(session) }
            run = RunProjection()
        } catch { if ownsSelection(owner), self.streamID == streamID || self.streamID == nil { self.error = errorMessage(error) } }
    }

    func checkPending() async {
        guard let owner = ownership(), let id = owner.sessionID else { return }
        do {
            let approval = try await owner.client.approvalPending(sessionID: id)
            guard ownsSelection(owner) else { return }
            let clarify = try await owner.client.clarifyPending(sessionID: id)
            guard ownsSelection(owner) else { return }
            run.approval = approval.pending; run.clarification = clarify.pending
        } catch { if ownsSelection(owner) { self.error = "Could not check pending input: " + errorMessage(error) } }
    }

    func approve(_ choice: ApprovalChoice) async {
        guard let owner = ownership(), let id = owner.sessionID, let approval = run.approval else { return }
        do {
            let response = try await owner.client.respondApproval(sessionID: id, choice: choice, approvalID: approval.approvalId)
            guard ownsSelection(owner), run.approval == approval else { return }
            guard response.ok == true else { throw MacFailure.message("Approval was not accepted. Refresh pending input.") }
            run.approval = nil
            await checkPending()
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func clarify(_ text: String) async {
        guard let owner = ownership(), let id = owner.sessionID, let pending = run.clarification, text.macNonEmpty != nil else { return }
        do {
            let response = try await owner.client.respondClarification(sessionID: id, response: text, clarifyID: pending.clarifyId)
            guard ownsSelection(owner), run.clarification == pending else { return }
            guard response.ok == true else { throw MacFailure.message("Clarification was not accepted. Refresh pending input.") }
            run.clarification = nil
            await checkPending()
        } catch { if ownsSelection(owner) { self.error = errorMessage(error) } }
    }

    func newSession() async {
        guard let owner = ownership(), !busy else { return }
        var errorOwner = owner
        busy = true
        defer { if ownsConnection(owner) { busy = false } }
        do {
            let result = try await owner.client.createSession(workspace: workspace.macNonEmpty, model: model.macNonEmpty, modelProvider: provider.macNonEmpty, profile: profile.macNonEmpty)
            guard ownsSelection(owner) else { return }
            guard let session = result.session else { throw MacFailure.message("The server did not return the new session.") }
            saveDraft()
            selectionGeneration += 1
            streamTask?.cancel(); streamTask = nil
            streaming = false; streamID = nil; streamDisconnected = false; run = RunProjection()
            draft = ""; attachments = []
            install(session)
            errorOwner = ownership() ?? owner
            panel = "Chat"
            try await reloadSessions()
        } catch { if ownsSelection(errorOwner) { self.error = errorMessage(error) } }
    }
}

extension String {
    var macNonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
