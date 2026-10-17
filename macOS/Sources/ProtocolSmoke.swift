#if DEBUG
import Foundation

enum ProtocolSmoke {
    @MainActor static func run(address: String) async throws {
        let url = try ServerAddress.parse(address)
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { throw MacFailure.message("Protocol smoke only accepts an explicit loopback fixture.") }
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("health"))
        let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard marker?["fixture"] as? String == "hermex-mac-protocol-v1" else { throw MacFailure.message("Refusing smoke against a non-fixture server. Nothing was mutated.") }
        let store = MacStore(persistence: false)
        func require(_ passed: Bool, _ message: String) throws { if !passed { throw MacFailure.message(message) } }
        await store.connect(address: address, password: "hermex-fixture-only", remember: false)
        try require(store.connected, store.error ?? "Fixture sign-in failed")
        try require(!store.modelCatalog.isEmpty && !store.providers.isEmpty && !store.profiles.isEmpty && !store.workspaces.isEmpty, "Configuration catalog decoding failed")
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
        await store.mutate(id, action: .delete)
        try require(store.selectedID == nil, "Delete did not clear conversation")
        await store.logout()
        try require(!store.connected, "Logout failed")
        print("FIXTURE SMOKE PASSED: app state + upstream auth/session/upload + native SSE interrupt/replay + read-only panels; no live server or model called.")
    }
}
#endif
