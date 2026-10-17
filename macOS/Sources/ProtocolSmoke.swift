#if DEBUG
import Foundation

enum ProtocolSmoke {
    @MainActor static func redirects(address: String, secondAddress: String) async throws {
        let first = try ServerAddress.parse(address)
        let second = try ServerAddress.parse(secondAddress)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in [first, second] {
            guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { throw MacFailure.message("Redirect smoke only accepts loopback fixtures.") }
            let (data, _) = try await session.data(from: url.appendingPathComponent("health"))
            let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard marker?["fixture"] as? String == "hermex-mac-redirect-v1" else { throw MacFailure.message("Refusing redirect smoke against a non-fixture server.") }
        }
        let headers = [CustomHeader(name: "CF-Access-Client-Id", value: "fixture-only-id"), CustomHeader(name: "CF-Access-Client-Secret", value: "fixture-only-secret"), CustomHeader(name: "X-Fixture-Connection", value: "fixture-only-generic"), CustomHeader(name: "accept", value: "incorrect-custom-accept"), CustomHeader(name: "content-type", value: "incorrect-custom-type")]
        for kind in ["same", "cross"] {
            let base = first.appendingPathComponent(kind)
            let api = APIClient(baseURL: base, session: session, customHeaderProvider: { headers })
            _ = try await api.health()
            _ = try await api.sendBoundedData(endpoint: .rawFile(sessionID: "fixture", path: "fixture.txt"), limit: 1024)
            _ = try await api.downloadData(from: base.appendingPathComponent("media"), using: session, mapsUnauthorized: false)
            try await MacStream.consume(client: api, streamID: "fixture", after: nil, headers: headers) { _, event in
                if case .streamEnd = event { return true }
                return false
            }
            if kind == "same" { _ = try await api.login(password: "fixture-only-password") }
            else {
                do {
                    _ = try await api.login(password: "fixture-only-password")
                    throw MacFailure.message("A cross-origin credential POST redirect was followed.")
                } catch APIError.http(let status, _) where status == 307 { }
            }
        }
        let api = APIClient(baseURL: first, session: session, customHeaderProvider: { headers })
        _ = try await api.downloadData(from: second.appendingPathComponent("capture/external-media"), using: session, mapsUnauthorized: false)
        print("FIXTURE REDIRECT SMOKE PASSED: same-origin, second-origin JSON/media/bounded/SSE, external media, fail-closed password POST.")
    }

    @MainActor static func run(address: String, requireHeaders: Bool = false) async throws {
        let url = try ServerAddress.parse(address)
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { throw MacFailure.message("Protocol smoke only accepts an explicit loopback fixture.") }
        let headers: [CustomHeader] = requireHeaders ? [
            CustomHeader(name: ConnectionHeaders.clientID, value: "fixture-only-id"),
            CustomHeader(name: ConnectionHeaders.clientSecret, value: "fixture-only-secret"),
            CustomHeader(name: "X-Fixture-Connection", value: "fixture-only-generic"),
            CustomHeader(name: "accept", value: "incorrect-custom-accept"),
            CustomHeader(name: "content-type", value: "incorrect-custom-type")
        ] : []
        var probe = URLRequest(url: url.appendingPathComponent("health"))
        headers.apply(to: &probe)
        let probeSession = URLSession(configuration: .ephemeral)
        defer { probeSession.invalidateAndCancel() }
        let guardDelegate = CrossOriginHeaderStripper(baseURL: url, customHeaderProvider: { headers })
        let (data, _) = try await probeSession.data(for: probe, delegate: guardDelegate)
        let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard marker?["fixture"] as? String == "hermex-mac-protocol-v1" else { throw MacFailure.message("Refusing smoke against a non-fixture server. Nothing was mutated.") }
        let vault = MacKeychain(service: "com.kenmercuslai.hermex-mac.protocol-smoke.\(UUID())")
        defer {
            try? vault.delete(account: "connections")
            try? vault.delete(account: url.absoluteString)
            try? ConnectionHeaderVault(vault: vault).clear(for: url)
        }
        var store = MacStore(persistence: requireHeaders, vault: vault)
        func require(_ passed: Bool, _ message: String) throws { if !passed { throw MacFailure.message(message) } }
        store.address = address
        store.connectionHeaders = headers.isEmpty ? ConnectionHeaders.placeholders : headers
        await store.connect(address: address, password: "hermex-fixture-only", remember: false)
        try require(store.connected, store.error ?? "Fixture sign-in failed")
        if requireHeaders {
            store.disconnect()
            store = MacStore(vault: vault)
            try require(store.connectionHeaders == headers, "Headers were not restored from the isolated Keychain after relaunch")
            try require(try vault.read(account: url.absoluteString) == nil, "Remember-password false unexpectedly saved the WebUI password")
            await store.connect(address: address, password: "hermex-fixture-only", remember: false)
            try require(store.connected, store.error ?? "Restored-header connection failed")
        }
        try require(!store.modelCatalog.isEmpty && !store.providers.isEmpty && !store.profiles.isEmpty && !store.workspaces.isEmpty, "Configuration catalog decoding failed")
        try require(store.sidebarRows.map(\.id) == ["fixture-welcome", "fixture-orphan"], "Hierarchy did not start collapsed or hid its orphan")
        try require(store.sidebarRows.first?.descendantCount == 3 && store.sidebarRows.first?.activeDescendantCount == 1, "Nested count/activity did not bubble to the owner")
        store.toggleSessionDisclosure("fixture-welcome")
        try require(store.selectedID == nil, "Disclosure unexpectedly selected a conversation")
        try require(store.sidebarRows.map(\.id) == ["fixture-welcome", "fixture-worker", "fixture-sibling", "fixture-orphan"], "Immediate children did not remain in source order")
        store.toggleSessionDisclosure("fixture-worker")
        try require(store.sidebarRows.count == 5 && store.sidebarRows[2].depth == 2, "Nested child not represented exactly once")
        await store.selectSession("fixture-nested")
        try require(store.detail?.readOnly == true && store.messages.first?.content?.contains("Explicit fixture") == true, "Child selection lost read-only history")
        store.toggleSessionDisclosure("fixture-welcome")
        await store.refresh()
        try require(store.selectedID == "fixture-nested" && store.sidebarRows.first?.containsSelectedDescendant == true, "Explicit collapse lost selected-child context")
        store.search = "citations"
        await store.refresh()
        try require(store.sidebarRows.map(\.id) == ["fixture-nested"] && store.sidebarRows.first?.context?.contains("fixture-worker") == true, "Search hid a collapsed matching child or invented its owner")
        store.search = ""
        await store.refresh()
        try require(store.expandedSessionIDs == ["fixture-worker"], "Refresh/search lost surviving disclosure choices")
        print("HIERARCHY SMOKE PASSED: collapsed owner, nested siblings, active descendant, orphan, read-only child selection, explicit collapse and hidden-child search.")
        await store.newSession()
        guard let id = store.selectedID, let api = store.api else { throw MacFailure.message("Fixture create failed") }
        await store.mutate(id, action: .rename("Mac pipeline smoke"))
        try require(store.detail?.title == "Mac pipeline smoke", "Rename readback failed")
        await store.mutate(id, action: .pin(true))
        try require(store.detail?.pinned == true, "Pin readback failed")
        await store.mutate(id, action: .archive(true))
        try require(store.detail?.archived == true, "Archive readback failed")
        await store.mutate(id, action: .archive(false))
        try require(store.detail?.archived == false, "Restore readback failed")
        store.model = "fixture-model"; store.provider = "fixture"; store.workspace = "/fixture/workspace"
        await store.saveSessionControls()
        try require(store.detail?.modelProvider == "fixture", "Model/provider update failed")
        store.search = "pipeline"
        await store.refresh()
        try require(store.sessions.count == 1, "Search failed")
        store.search = ""
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.currentDirectoryPath + "/.build")
        let file = directory.appendingPathComponent("hermex-fixture-\(UUID()).txt")
        try Data("fixture data".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await store.upload([file])
        try require(store.attachments.count == 1, "Upload failed")
        store.profile = "research" // next new session, not this existing conversation
        store.draft = "Protocol test only"
        await store.send()
        await store.waitForStream()
        try require(store.streamDisconnected, "Interrupted stream was not surfaced")
        try require(store.run.sequence != nil, "Replay cursor was not captured")
        await store.reattach()
        await store.waitForStream()
        try require(!store.streaming && !store.streamDisconnected, "Replay did not finish")
        try require(store.messages.contains(where: { $0.role == "assistant" && $0.content?.contains("streamed") == true }), "Conversation history readback failed")
        try require(store.messages.filter { $0.role == "user" }.count == 1, "A user turn was duplicated")
        let files = try await api.directoryList(sessionID: id)
        try require(files.entries?.first?.name == "README.md", "Workspace read failed")
        let preview = try await api.file(sessionID: id, path: "README.md")
        try require(preview.content?.contains("Fixture") == true, "File preview failed")
        let skills = try await api.skills()
        try require(skills.skills?.count == 1, "Skills list failed")
        let skill = try await api.skillContent(name: "fixture-skill", file: nil)
        try require(skill.content?.contains("Protocol test") == true, "Skill content failed")
        let memory = try await api.memory()
        try require(memory.memory?.contains("Fixture") == true, "Memory read failed")
        let crons = try await api.crons()
        try require(crons.jobs?.count == 1, "Tasks read failed")
        let output = try await api.cronOutput(jobID: "fixture-job", limit: 5)
        try require(output.outputs?.count == 1, "Task output read failed")
        let insights = try await api.insights(days: 30)
        try require(insights.totalTokens == 36, "Insights read failed")
        let stopped = try await api.cancelChat(streamID: "fixture-only-completed-stream")
        try require(stopped.ok != false, "Stop request failed")
        let approval = try await api.respondApproval(sessionID: id, choice: .deny, approvalID: "fixture-only-approval")
        try require(approval.ok == true, "Approval response request failed")
        let clarified = try await api.respondClarification(sessionID: id, response: "fixture-only-answer", clarifyID: "fixture-only-clarification")
        try require(clarified.ok == true, "Clarification response request failed")
        await store.mutate(id, action: .delete)
        try require(store.selectedID == nil, "Delete did not clear conversation")
        await store.logout()
        try require(!store.connected, "Logout failed")
        try require(try ConnectionHeaderVault(vault: vault).load(for: url).isEmpty, "Sign-out did not forget connection headers")
        print("FIXTURE SMOKE PASSED: app state + upstream auth/session/upload + native SSE interrupt/replay + read-only panels; no live server or model called.")
    }
}
#endif
