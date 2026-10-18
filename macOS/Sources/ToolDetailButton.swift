import SwiftUI

/// One compact disclosure button for history, saved snippets and live tool activity.
/// Copy is deliberately a sibling button, so copying never changes disclosure.
struct ToolDetailButton: View {
    let item: ToolDisplayItem
    let scope: String
    let mode: ToolDisplayMode
    @MacState<ToolDisclosureState> private var disclosure = ToolDisclosureState()
    private var context: ToolDisclosureContext {
        ToolDisclosureContext(scope: "\(scope)/\(item.id)/\(item.runID?.uuidString ?? "settled")", mode: mode, phase: item.phase, revision: item.revision)
    }
    private var expanded: Bool { disclosure.isExpanded(in: context) }
    private var status: String {
        switch item.status { case .running: "Running"; case .completed: "Completed"; case .failed: "Failed" }
    }
    private var icon: String {
        switch item.status { case .running: "terminal"; case .completed: "checkmark.circle"; case .failed: "exclamationmark.circle" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { disclosure.toggle(in: context) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon).foregroundStyle(item.status == .failed ? Color.red : .secondary)
                        Text(item.name).fontWeight(.medium).lineLimit(1)
                        Text(status).foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .help(expanded ? "Hide tool details" : "Show tool details")
                    .accessibilityLabel("\(item.name), \(status), \(expanded ? "expanded" : "collapsed")")
                    .accessibilityIdentifier("tool-detail-toggle")
                Button { copyText(item.detail) } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless).help("Copy tool details")
                    .accessibilityLabel("Copy \(item.name) details")
                Spacer(minLength: 0)
            }
            if expanded {
                Text(item.detail.isEmpty ? "No details available." : item.detail)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            }
        }.onChange(of: context) { _, context in disclosure.synchronize(with: context) }
    }
}

struct ToolDisplaySettingsView: View {
    @AppStorage(ToolDisplayMode.key) private var storedMode = ToolDisplayMode.collapsed.rawValue
    private var selection: Binding<ToolDisplayMode> {
        Binding(get: { ToolDisplayMode(rawValue: storedMode) ?? .collapsed }, set: { storedMode = $0.rawValue })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tool details").font(.headline)
            Picker("Automatically show", selection: selection) {
                Text("Always collapsed (default)").tag(ToolDisplayMode.collapsed)
                Text("During execution; collapse on reply").tag(ToolDisplayMode.whileExecuting)
                Text("Always expanded").tag(ToolDisplayMode.expanded)
            }.accessibilityIdentifier("tool-display-mode")
            Text("Applies immediately to all tool buttons. Every mode still lets you click to show or hide details. Manual choices last until the tool/reply phase, session or mode changes. Saved history is collapsed in the execution-only mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
