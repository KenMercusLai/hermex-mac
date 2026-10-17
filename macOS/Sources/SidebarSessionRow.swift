import SwiftUI

/// Two sibling buttons: disclosure never selects or loads a conversation. The
/// enclosing list attaches context actions to this exact row, including children.
struct SidebarSessionRow: View {
    let row: SessionHierarchy.Row
    let expanded: Bool
    let selected: Bool
    let select: () -> Void
    let toggle: () -> Void

    private var session: SessionSummary { row.session }
    private var title: String { session.title ?? "Untitled" }
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if row.descendantCount > 0 {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 18, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless)
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(row.descendantCount) subagents under \(title)")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("session-disclosure-\(row.id)")
                    .help("\(expanded ? "Collapse" : "Expand") subagents without changing the selected conversation")
            } else { Color.clear.frame(width: 18, height: 24).accessibilityHidden(true) }
            Button(action: select) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: session.archived == true ? "archivebox" : session.pinned == true ? "pin.fill" : "bubble.left")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(session.matchPreview ?? session.model ?? "\(session.messageCount ?? 0) messages")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let context = row.context {
                            Text(context).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(context)
                        }
                        if row.depth > 8 { Text("Nesting level \(row.depth)").font(.caption2).foregroundStyle(.secondary) }
                        if row.descendantCount > 0 {
                            Text("\(row.descendantCount) \(row.descendantCount == 1 ? "subagent" : "subagents")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if row.activeDescendantCount > 0 {
                            Label("\(row.activeDescendantCount) active \(row.activeDescendantCount == 1 ? "subagent" : "subagents")", systemImage: "circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if !expanded && row.containsSelectedDescendant {
                            Label("Selected conversation in branch", systemImage: "arrow.turn.down.right")
                                .font(.caption2).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                    if SessionHierarchy.isActive(session) {
                        Circle().fill(.green).frame(width: 6, height: 6).padding(.top, 5).accessibilityLabel("Session active")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("session-select-\(row.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
        }.padding(.leading, CGFloat(min(row.depth, 8)) * 12).padding(.vertical, 4)
    }
}
