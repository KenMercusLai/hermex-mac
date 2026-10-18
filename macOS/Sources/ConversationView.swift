import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @ObservedObject var store: MacStore
    @MacState<Bool> private var importing = false
    @MacState<Bool> private var showControls = false
    @MacState<String> private var clarification = ""
    @MacState<Bool> private var follow = true
    var body: some View {
        VStack(spacing: 0) {
            if let detail = store.detail {
                header(detail)
                Divider()
                if showControls { controls.padding(16).background(.bar); Divider() }
                transcript
                if store.run.approval != nil || store.run.clarification != nil { pendingInput.padding(16).background(Color.orange.opacity(0.06)); Divider() }
                if detail.archived == true {
                    HStack { Label("This session is archived.", systemImage: "archivebox"); Spacer(); Button("Restore") { if let id = store.selectedID { Task { await store.mutate(id, action: .archive(false)) } } } }.padding(16)
                } else if detail.readOnly == true || detail.isReadOnly == true {
                    Label("This external session is read-only. Start a new session to continue.", systemImage: "lock").padding(20).foregroundStyle(.secondary)
                } else { composer }
            } else {
                ContentUnavailableView {
                    Label("A place to think and build", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text(store.selectedID == nil ? "Select a conversation, or start a new session with your agent." : "Loading conversation…")
                } actions: {
                    Button("New Session") { Task { await store.newSession() } }.buttonStyle(.borderedProminent).disabled(store.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.upload(urls) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }.task(id: store.selectedID) {
            guard store.selectedID != nil else { return }
            await store.checkPending()
            // Approvals/clarification can also arrive on their separate upstream channels.
            // Bounded read-only polling while a run is active covers those legacy hosts.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                if store.streaming { await store.checkPending() }
            }
        }
    }

    private func header(_ detail: SessionDetail) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(detail.title ?? "Untitled").font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(store.streamDisconnected ? .orange : store.streaming ? .green : .secondary.opacity(0.6)).frame(width: 6, height: 6)
                    Text(store.streamDisconnected ? "Disconnected · response is preserved" : store.streaming ? "Agent is working" : "\(store.messages.count) messages · \(detail.model ?? "Server default")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { Task { await store.reattach() } } label: { Label(store.streamDisconnected ? "Reattach" : "Refresh Run", systemImage: "arrow.triangle.2.circlepath") }.help("Refresh history or reattach an active run — never resends a message")
            Button { showControls.toggle() } label: { Image(systemName: "slider.horizontal.3") }.help("Model, provider, profile and workspace")
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Server default", text: $store.model).textFieldStyle(.roundedBorder)
                        Menu { ForEach(store.modelCatalog) { group in
                            Section(group.name) { ForEach(group.allModels) { model in
                                Button(model.displayName) { store.model = model.id; if let provider = model.providerID { store.provider = provider } }
                            } }
                        } } label: { Image(systemName: "list.bullet") }.menuStyle(.borderlessButton).frame(width: 25)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Server default", text: $store.provider).textFieldStyle(.roundedBorder)
                        Menu { ForEach(store.providers, id: \.id) { item in Button(item.displayName ?? item.id ?? "Provider") { store.provider = item.id ?? "" } } } label: { Image(systemName: "list.bullet") }.menuStyle(.borderlessButton).frame(width: 25)
                    }
                }
            }
            HStack {
                Text("Workspace").font(.caption).foregroundStyle(.secondary)
                TextField("Server-side working directory", text: $store.workspace).textFieldStyle(.roundedBorder)
                Menu("Choose") { ForEach(store.workspaces, id: \.path) { item in Button(item.name ?? item.path ?? "Workspace") { store.workspace = item.path ?? "" } } }
                Button("Apply to Session") { Task { await store.saveSessionControls() } }.disabled(store.streaming || store.busy)
            }
            HStack {
                Text("Profile for new sessions").font(.caption).foregroundStyle(.secondary)
                Picker("Profile", selection: $store.profile) {
                    Text("Server default").tag("")
                    ForEach(store.profiles) { item in Text(item.displayName).tag(item.name ?? "") }
                }.labelsHidden().frame(maxWidth: 200)
                Text("Execution and tool permissions are enforced by the server.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.disabled(store.busy)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if (store.detail?.messagesOffset ?? 0) > 0 { Button("Load Earlier Messages") { Task { await store.loadOlder() } }.frame(maxWidth: .infinity) }
                    if store.messages.isEmpty, !store.streaming {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What are we working on?").font(.title2.weight(.semibold))
                            Text("Ask a question, attach a file, or give your agent a task.").foregroundStyle(.secondary)
                        }.padding(.vertical, 35)
                    }
                    ForEach(Array(store.messages.enumerated()), id: \.offset) { index, message in
                        MessageRow(message: message, download: { reference in Task { await store.saveMedia(reference) } }).id("message-\(index)")
                    }
                    if let tools = store.detail?.toolCalls, !tools.isEmpty {
                        DisclosureGroup("\(tools.count) recorded tool calls") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(tool.name ?? "Tool", systemImage: "terminal").font(.caption.bold())
                                        Text(tool.snippet ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, 10)
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                    if store.streaming || !store.run.text.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(store.streamDisconnected ? "Response paused · reattach to continue" : "Hermes", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if !store.run.reasoning.isEmpty { DisclosureGroup("Reasoning") { Text(store.run.reasoning).textSelection(.enabled).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) } }
                            ForEach(store.run.tools) { tool in
                                DisclosureGroup {
                                    Text(tool.preview).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                                } label: { Label(tool.name, systemImage: tool.failed ? "exclamationmark.circle" : tool.complete ? "checkmark.circle" : "terminal").font(.callout).foregroundStyle(tool.failed ? .red : .secondary) }
                            }
                            if !store.run.text.isEmpty { MessageContent(text: store.run.text, download: { reference in Task { await store.saveMedia(reference) } }) }
                            if !store.streamDisconnected { ProgressView().controlSize(.small) }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(28).frame(maxWidth: 940).frame(maxWidth: .infinity)
            }.onChange(of: store.messages.count) { _, _ in if follow { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.run.text) { _, _ in if follow { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.selectedID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.attachments) { file in
                            HStack(spacing: 6) {
                                Image(systemName: file.isImage ? "photo" : "doc")
                                Text(file.name).lineLimit(1)
                                Button { store.attachments.removeAll { $0.id == file.id }; store.saveDraft() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Remove attachment")
                            }.font(.caption).padding(8).background(.quaternary.opacity(0.4), in: Capsule())
                        }
                    }
                }
            }
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty { Text("Message your agent…").foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 12).allowsHitTesting(false) }
                    MacComposer(text: $store.draft, enabled: !store.busy) { Task { await store.send() } }.frame(height: 94)
                }
                HStack {
                    Button { importing = true } label: { Image(systemName: "paperclip") }.help("Attach files or images (up to 20 MB each)").disabled(store.busy || store.streaming)
                    Text(store.busy ? "Working…" : "Return to send · Shift-Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if store.streaming {
                        if store.streamDisconnected { Button("Reattach") { Task { await store.reattach() } } }
                        Button { Task { await store.stop() } } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.bordered)
                    } else {
                        Button { Task { await store.send() } } label: { Label("Send", systemImage: "arrow.up") }.buttonStyle(.borderedProminent).disabled(store.busy || (store.draft.macNonEmpty == nil && store.attachments.isEmpty))
                    }
                }.padding(.horizontal, 12).padding(.bottom, 10)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary))
            HStack {
                Text(store.workspace.isEmpty ? "Server default workspace" : store.workspace).font(.caption2).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                Spacer()
                Toggle("Follow response", isOn: $follow).toggleStyle(.checkbox).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 10)
    }

    private var pendingInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let approval = store.run.approval {
                Label("Agent is waiting for approval", systemImage: "hand.raised.fill").font(.headline)
                if let description = approval.description { Text(description).textSelection(.enabled) }
                if let command = approval.command { Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }
                HStack {
                    Button("Deny", role: .destructive) { Task { await store.approve(.deny) } }
                    Button("Allow Once") { Task { await store.approve(.once) } }.buttonStyle(.borderedProminent)
                    Text("Review the command before granting access.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let pending = store.run.clarification {
                Label("Your input is needed", systemImage: "questionmark.bubble").font(.headline)
                Text(pending.displayQuestion).textSelection(.enabled)
                HStack { ForEach(pending.displayChoices, id: \.self) { choice in Button(choice) { Task { await store.clarify(choice) } } } }
                HStack {
                    TextField("Your response", text: $clarification).textFieldStyle(.roundedBorder)
                    Button("Reply") { let text = clarification; clarification = ""; Task { await store.clarify(text) } }.disabled(clarification.macNonEmpty == nil)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var download: (MediaReference) -> Void
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isUser ? "You" : message.role == "assistant" ? "Hermes" : message.name ?? message.role ?? "Message", systemImage: isUser ? "person.crop.circle" : message.role == "assistant" ? "sparkles" : "terminal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { copyText(message.content ?? "") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy message as Markdown")
            }
            if let reasoning = message.reasoning, !reasoning.isEmpty { DisclosureGroup("Reasoning") { Text(reasoning).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.font(.callout).foregroundStyle(.secondary) }
            if message.role == "tool" {
                DisclosureGroup("Tool output") { Text(message.content ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else { MessageContent(text: message.content ?? "", download: download) }
            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    Label(attachment.name ?? attachment.path ?? "Attachment", systemImage: attachment.isImage == true ? "photo" : "doc").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.padding(isUser ? 16 : 0).frame(maxWidth: .infinity, alignment: .leading).background(isUser ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }
}
