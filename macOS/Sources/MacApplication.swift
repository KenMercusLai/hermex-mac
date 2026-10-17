import SwiftUI
import AppKit

// SDK 27 also exports a State macro whose Xcode-only plugin is absent in CLT.
// Alias the established property-wrapper TYPE to avoid macro lookup entirely.
typealias MacState<Value> = SwiftUI.State<Value>

struct HermexApplication: App {
    @StateObject private var store: MacStore
    init() {
        #if DEBUG
        _store = StateObject(wrappedValue: MacStore(persistence: !CommandLine.arguments.contains("--isolated")))
        #else
        _store = StateObject(wrappedValue: MacStore())
        #endif
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        Window("Hermex for Mac", id: "main") {
            RootView(store: store).frame(minWidth: 920, minHeight: 620)
                .tint(Color(red: 0.62, green: 0.40, blue: 0.16))
        }.defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { Task { await store.newSession() } }.keyboardShortcut("n").disabled(!store.connected || store.busy)
            }
            CommandMenu("Session") {
                Button("Refresh Sessions") { Task { await store.refresh() } }.keyboardShortcut("r").disabled(!store.connected)
                Button("Reattach Active Run") { Task { await store.reattach() } }.disabled(store.selectedID == nil)
                Button("Stop Response") { Task { await store.stop() } }.disabled(store.streamID == nil)
            }
        }
        Settings { ConnectionSettings(store: store).padding(24).frame(width: 550) }
    }
}

struct RootView: View {
    @ObservedObject var store: MacStore
    var body: some View {
        Group {
            if store.connected {
                NavigationSplitView {
                    SidebarView(store: store).navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 390)
                } detail: {
                    VStack(spacing: 0) {
                        if let error = store.error { ErrorBanner(text: error) { store.error = nil } }
                        if store.panel == "Chat" { ConversationView(store: store) }
                        else { ServerPanelView(store: store, kind: store.panel).id(store.address + store.panel + (store.selectedID ?? "")) }
                    }
                }
            } else { WelcomeView(store: store) }
        }
    }
}

struct ErrorBanner: View {
    let text: String
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss error")
        }.padding(12).background(Color.orange.opacity(0.1))
    }
}

struct WelcomeView: View {
    @ObservedObject var store: MacStore
    var body: some View {
        HStack(spacing: 60) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 52, weight: .light)).foregroundStyle(.brown)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your agent.\nA native Mac home.").font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("HERMEX FOR MAC").font(.caption.weight(.medium)).tracking(3).foregroundStyle(.secondary)
                }
                Text("Conversations, tools, and your workspace —\nconnected directly to your own Hermes server.").font(.title3).foregroundStyle(.secondary).lineSpacing(4)
                Label("Private by design. No hosted backend.", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: 410, alignment: .leading)
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect to Hermes").font(.title2.bold())
                Text("Use your existing hermes-webui address.\nThe agent stays on your server.").foregroundStyle(.secondary)
                ConnectionForm(store: store)
            }.padding(28).frame(width: 410).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.brown.opacity(0.065)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

struct ConnectionForm: View {
    @ObservedObject var store: MacStore
    @MacState<String> private var password = ""
    @MacState<Bool> private var remember = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.servers.isEmpty {
                Menu("Saved servers") {
                    ForEach(store.servers) { server in
                        Button(server.address) { store.address = server.address; password = "" }
                    }
                }.disabled(store.busy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL").font(.caption.weight(.medium))
                TextField("http://127.0.0.1:8787", text: $store.address).textFieldStyle(.roundedBorder).accessibilityIdentifier("server-url").disabled(store.busy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Webui password").font(.caption.weight(.medium))
                SecureField("Password (or saved in Keychain)", text: $password).textFieldStyle(.roundedBorder).onSubmit { connect() }.accessibilityIdentifier("server-password").disabled(store.busy)
            }
            Toggle("Remember password in macOS Keychain", isOn: $remember).font(.callout).disabled(store.busy)
            if store.address.lowercased().hasPrefix("http://"), !store.address.contains("127.0.0.1"), !store.address.contains("localhost") {
                Label("HTTP does not encrypt your password or data. Use HTTPS or a trusted private network.", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
            }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Button(action: connect) {
                HStack { if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "Connecting…" : "Connect").frame(maxWidth: .infinity) }.padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(store.busy).accessibilityIdentifier("connect")
            Text("No server or model runtime is bundled. Direct Hermes dashboard, passkey and SSO sign-in are not supported in this release.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func connect() {
        guard !store.busy else { return }
        let entered = password
        let connectionAddress = store.address
        let shouldRemember = remember
        password = ""
        Task { await store.connect(address: connectionAddress, password: entered, remember: shouldRemember) }
    }
}

struct ConnectionSettings: View {
    @ObservedObject var store: MacStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Hermex for Mac").font(.title.bold())
            if store.connected {
                Label(store.address, systemImage: "network").textSelection(.enabled)
                Text("Passwords stay in the login Keychain. Session cookies and drafts are kept only in app memory, isolated per connection.").foregroundStyle(.secondary)
                HStack {
                    Button("Disconnect / Switch Server") { store.disconnect() }
                    Button("Sign Out & Forget Password", role: .destructive) { Task { await store.logout() } }
                }
            } else { ConnectionForm(store: store) }
            Divider()
            Text("A community macOS port of uzairansaruzi/hermex. MIT licensed. Agent execution, tools and file permissions remain the server's responsibility.").font(.caption).foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Native SwiftUI + AppKit").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: MacStore
    @MacState<SessionSummary?> private var rename: SessionSummary?
    @MacState<String> private var newTitle = ""
    @MacState<SessionSummary?> private var deleting: SessionSummary?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.brown)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermex").font(.title3.bold())
                    Text(store.connectionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
            }.padding(16)
            Button { Task { await store.newSession() } } label: { Label("New Session", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }.buttonStyle(.bordered).padding(.horizontal, 12).disabled(store.busy)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations", text: $store.search).textFieldStyle(.plain).onSubmit { Task { await store.refresh() } }
                if !store.search.isEmpty { Button { store.search = ""; Task { await store.refresh() } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7)).padding(12)
            List {
                Section("Conversations") {
                    if store.sessions.isEmpty { Text(store.search.isEmpty ? "No sessions yet" : "No matching sessions").foregroundStyle(.secondary).font(.callout) }
                    ForEach(store.sessions) { session in
                        Button { Task { await store.selectSession(session.id) } } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: session.archived == true ? "archivebox" : session.pinned == true ? "pin.fill" : "bubble.left").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title ?? "Untitled").font(.callout.weight(.medium)).lineLimit(2)
                                    Text(session.matchPreview ?? session.model ?? "\(session.messageCount ?? 0) messages").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if session.isStreaming == true { Circle().fill(.green).frame(width: 6, height: 6).padding(.top, 5) }
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).listRowBackground(store.selectedID == session.id && store.panel == "Chat" ? Color.accentColor.opacity(0.12) : .clear)
                            .contextMenu {
                                Button("Rename…") { rename = session; newTitle = session.title ?? "" }
                                Button(session.pinned == true ? "Unpin" : "Pin") { Task { await store.mutate(session.id, action: .pin(session.pinned != true)) } }
                                Button(session.archived == true ? "Restore" : "Archive") { Task { await store.mutate(session.id, action: .archive(session.archived != true)) } }
                                Divider()
                                Button("Delete…", role: .destructive) { deleting = session }
                            }
                    }
                }
                Section("Server") {
                    panelButton("Workspace", icon: "folder")
                    panelButton("Skills", icon: "books.vertical")
                    panelButton("Memory", icon: "brain")
                    panelButton("Tasks", icon: "calendar.badge.clock")
                    panelButton("Insights", icon: "chart.bar.xaxis")
                }
            }.listStyle(.sidebar)
            Divider()
            HStack {
                Toggle("Archived", isOn: $store.showArchived).toggleStyle(.checkbox).font(.caption).onChange(of: store.showArchived) { _, _ in Task { await store.refresh() } }
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh sessions · ⌘R")
            }.padding(12)
        }.navigationTitle("Hermex")
            .alert("Rename Session", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Session title", text: $newTitle)
                Button("Cancel", role: .cancel) { rename = nil }
                Button("Rename") { if let row = rename { Task { await store.mutate(row.id, action: .rename(newTitle)) } }; rename = nil }.disabled(newTitle.macNonEmpty == nil)
            }
            .alert("Delete this session permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) { if let row = deleting { Task { await store.mutate(row.id, action: .delete) } }; deleting = nil }
            } message: { Text("“\(deleting?.title ?? "Untitled")” and its conversation will be deleted from your server. This cannot be undone.") }
    }
    private func panelButton(_ name: String, icon: String) -> some View {
        Button { store.panel = name } label: { Label(name, systemImage: icon).font(.callout).padding(.vertical, 3) }.buttonStyle(.plain).listRowBackground(store.panel == name ? Color.accentColor.opacity(0.12) : .clear)
    }
}
