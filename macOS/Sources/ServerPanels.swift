import SwiftUI
import AppKit
import Charts

struct ServerPanelView: View {
    @ObservedObject var store: MacStore
    let kind: String
    @MacState<Bool> private var loading = false
    @MacState<String?> private var failure: String?
    @MacState<[WorkspaceEntry]> private var entries: [WorkspaceEntry] = []
    @MacState<String> private var path = ""
    @MacState<String?> private var preview: String?
    @MacState<String> private var previewTitle = ""
    @MacState<NSImage?> private var previewImage: NSImage?
    @MacState<[SkillSummary]> private var skills: [SkillSummary] = []
    @MacState<String> private var skillSearch = ""
    @MacState<MemoryResponse?> private var memory: MemoryResponse?
    @MacState<InsightsResponse?> private var insights: InsightsResponse?
    @MacState<Int> private var period = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind).font(.title2.weight(.semibold))
                    Text(kind == "Workspace" ? "Read-only · \(store.detail?.workspace ?? "select a session")" : "Server-side · read-only").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading || (kind == "Tasks" && store.tasksLoading) { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(loading)
            }.padding(24)
            Divider()
            if let failure { ErrorBanner(text: failure) { self.failure = nil } }
            if kind == "Workspace" { workspaceBrowser }
            else if kind == "Skills" { skillsBrowser }
            else if kind == "Memory" { memoryBrowser }
            else if kind == "Tasks" { tasksBrowser }
            else { insightsBrowser }
        }.task(id: kind == "Tasks" ? store.connectionScope : kind) { await load() }
    }

    @ViewBuilder private var workspaceBrowser: some View {
        if store.selectedID == nil {
            ContentUnavailableView("Select a conversation", systemImage: "folder", description: Text("Workspace access is scoped to a server session. Select or create one first."))
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Button { let components = path.split(separator: "/"); path = components.dropLast().joined(separator: "/"); Task { await loadFiles() } } label: { Image(systemName: "arrow.up") }.disabled(path.isEmpty)
                        Button("Root") { path = ""; Task { await loadFiles() } }
                        Text(path.isEmpty ? "/" : path).font(.caption).lineLimit(1).textSelection(.enabled)
                        Spacer()
                    }.padding(12)
                    List(entries) { entry in
                        Button { Task { await open(entry) } } label: {
                            HStack {
                                Image(systemName: entry.isBrowsableDirectory ? "folder.fill" : "doc.text").foregroundStyle(entry.isBrowsableDirectory ? .blue : .secondary)
                                Text(entry.name ?? entry.path ?? "File").lineLimit(1)
                                Spacer()
                                if entry.targetOutsideWorkspace == true { Image(systemName: "lock").foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(entry.targetOutsideWorkspace == true)
                    }.overlay { if entries.isEmpty, !loading { Text("No entries").foregroundStyle(.secondary) } }
                }.frame(minWidth: 230, idealWidth: 280)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !previewTitle.isEmpty {
                            HStack {
                                Text(previewTitle).font(.headline).textSelection(.enabled)
                                Spacer()
                                if let preview { Button("Copy") { copyText(preview) } }
                            }
                        }
                        if let image = previewImage { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
                        else if let preview {
                            Text(preview).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else { ContentUnavailableView("File Preview", systemImage: "doc.text.magnifyingglass", description: Text("Select a text file or image. Remote HTML is shown as source, never executed.")) }
                    }.padding(24)
                }.frame(minWidth: 300, maxWidth: .infinity)
            }
        }
    }

    private var skillsBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Filter skills", text: $skillSearch).textFieldStyle(.roundedBorder).padding(12)
                List(skills.filter { skillSearch.isEmpty || ($0.name ?? "").localizedCaseInsensitiveContains(skillSearch) }) { skill in
                    Button { Task { await loadSkill(skill) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(skill.name ?? "Skill").font(.headline); if skill.disabled == true { Text("Disabled").font(.caption).foregroundStyle(.secondary) } }
                            Text(skill.description ?? skill.category ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }.frame(minWidth: 250, idealWidth: 310)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview { Text(previewTitle).font(.title2.bold()); NativeMarkdown(text: preview) }
                    else { ContentUnavailableView("Skills Library", systemImage: "books.vertical", description: Text("Select a skill to read its instructions. Enabling and editing stay in your webui.")) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 300)
        }
    }

    private var memoryBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let memory {
                    memorySection("Memory", text: memory.memory)
                    memorySection("User", text: memory.user)
                    memorySection("Soul", text: memory.soul)
                    if let context = memory.projectContext { memorySection(memory.projectContextName ?? "Project context", text: context) }
                } else if !loading { ContentUnavailableView("Memory unavailable", systemImage: "brain", description: Text("The server did not return memory content.")) }
            }.padding(28).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }
    private func memorySection(_ title: String, text: String?) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(title).font(.headline); Spacer(); if let text { Button { copyText(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy \(title)") } }
                if let text, !text.isEmpty { NativeMarkdown(text: text) }
                else { Text("No content reported").foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tasksBrowser: some View {
        HSplitView {
            List(store.taskJobs) { job in
                let count = store.taskWorkerCount(for: job)
                HStack(alignment: .top, spacing: 4) {
                    if count > 0 {
                        Button { store.toggleTaskDisclosure(job.id) } label: {
                            Image(systemName: store.expandedTaskIDs.contains(job.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).frame(width: 18, height: 24)
                        }.buttonStyle(.borderless)
                            .accessibilityLabel("\(store.expandedTaskIDs.contains(job.id) ? "Collapse" : "Expand") \(count) subagents under \(job.name ?? job.id)")
                            .accessibilityIdentifier("task-disclosure-\(job.id)")
                            .help("Show subagents without selecting a task or conversation")
                    } else { Color.clear.frame(width: 18, height: 24).accessibilityHidden(true) }
                    Button { Task { await store.loadTaskOutput(job) } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Image(systemName: job.enabled == false ? "pause.circle" : "clock"); Text(job.name ?? job.id).font(.headline); Spacer() }
                            Text(job.scheduleDisplay ?? job.schedule?.displayText ?? "Schedule not reported").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            if let status = job.lastStatus { Text("Last run: \(status)").font(.caption).foregroundStyle(.secondary) }
                            Text(job.prompt ?? "").font(.callout).lineLimit(4)
                            if count > 0 { Text("\(count) \(count == 1 ? "subagent" : "subagents")").font(.caption).foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.vertical, 10)
                ForEach(store.taskRows(for: job)) { row in
                    SidebarSessionRow(row: row, expanded: store.expandedTaskWorkerIDs.contains(row.id),
                                      selected: store.selectedID == row.id,
                                      select: { Task { await store.selectSession(row.id) } },
                                      toggle: { store.toggleTaskWorkerDisclosure(row.id) })
                        .padding(.leading, 20)
                }
            }.frame(minWidth: 280, idealWidth: 340).overlay {
                if store.taskJobs.isEmpty, !store.tasksLoading { Text("No scheduled tasks").foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failure = store.taskFailure { Text(failure).foregroundStyle(.red) }
                    if let preview = store.taskPreview { Text(store.taskPreviewTitle).font(.title2.bold()); NativeMarkdown(text: preview) }
                    else { ContentUnavailableView("Scheduled Tasks", systemImage: "calendar.badge.clock", description: Text("Select a task to read recent output. Expand a task to open its subagents. Creating, editing and running tasks stay in webui.")) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 300)
        }
    }

    private var insightsBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Usage overview").font(.title3.bold())
                    Spacer()
                    Picker("Period", selection: $period) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.frame(width: 160).onChange(of: period) { _, _ in Task { await load() } }
                }
                if let insights {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                        metric("Sessions", value: insights.totalSessions.map(String.init))
                        metric("Messages", value: insights.totalMessages.map(String.init))
                        metric("Input tokens", value: insights.totalInputTokens.map { $0.formatted() })
                        metric("Output tokens", value: insights.totalOutputTokens.map { $0.formatted() })
                        metric("Estimated cost", value: insights.totalCost.map { $0.formatted(.currency(code: "USD")) })
                    }
                    if let days = insights.dailyTokens, !days.isEmpty {
                        GroupBox("Daily tokens") {
                            Chart(Array(days.enumerated()), id: \.offset) { _, day in
                                BarMark(x: .value("Date", day.date ?? ""), y: .value("Tokens", (day.inputTokens ?? 0) + (day.outputTokens ?? 0)))
                            }.frame(height: 230).padding(16)
                        }
                    }
                    if let models = insights.models, !models.isEmpty {
                        Text("Models").font(.headline)
                        ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                            HStack { Text(model.model ?? "Unknown model"); Spacer(); Text(model.totalTokens?.formatted() ?? "Not reported").foregroundStyle(.secondary) }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Text("Reported by your server. Missing figures are not estimated by this app; model costs may be estimates.").font(.caption).foregroundStyle(.secondary)
                } else if !loading { ContentUnavailableView("Insights unavailable", systemImage: "chart.bar", description: Text("Your server may not support this endpoint.")) }
            }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }
    private func metric(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Not reported").font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        if kind == "Tasks" { await store.reloadTasks(); return }
        guard let api = store.api else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            switch kind {
            case "Workspace": await loadFiles()
            case "Skills": skills = try await api.skills().skills ?? []
            case "Memory": memory = try await api.memory()
            case "Insights": insights = try await api.insights(days: period)
            default: break
            }
        } catch { failure = "\(kind) could not be loaded: " + store.errorMessage(error) }
    }
    private func loadFiles() async {
        guard let api = store.api, let id = store.selectedID else { return }
        do {
            let response = try await api.directoryList(sessionID: id, path: path)
            if let error = response.error { throw MacFailure.message(error) }
            entries = (response.entries ?? []).sorted { left, right in
                if left.isBrowsableDirectory != right.isBrowsableDirectory { return left.isBrowsableDirectory }
                return (left.name ?? "").localizedStandardCompare(right.name ?? "") == .orderedAscending
            }
            failure = nil
        } catch { failure = store.errorMessage(error) }
    }
    private func open(_ entry: WorkspaceEntry) async {
        guard let api = store.api, let id = store.selectedID, let remote = entry.path else { return }
        if entry.isBrowsableDirectory { path = remote; await loadFiles(); return }
        loading = true; failure = nil; preview = nil; previewImage = nil; previewTitle = entry.name ?? remote
        defer { loading = false }
        do {
            let ext = (remote as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) {
                let data = try await api.rawFilePreviewData(sessionID: id, path: remote)
                guard let image = NSImage(data: data) else { throw MacFailure.message("Image format could not be decoded.") }
                previewImage = image
            } else {
                let file = try await api.file(sessionID: id, path: remote)
                if let error = file.error { throw MacFailure.message(error) }
                guard !file.isBinary else { throw MacFailure.message("This binary file cannot be shown as text.") }
                preview = file.content ?? ""
                if file.isTruncated { preview = (preview ?? "") + "\n\n[Server preview truncated]" }
            }
        } catch { failure = store.errorMessage(error) }
    }
    private func loadSkill(_ skill: SkillSummary) async {
        guard let api = store.api, let name = skill.name else { return }
        do {
            let result = try await api.skillContent(name: name, file: nil)
            previewTitle = name; preview = result.content ?? "No content returned."
        } catch { failure = store.errorMessage(error) }
    }

}
