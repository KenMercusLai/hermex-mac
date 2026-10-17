import AppKit
import SwiftUI

enum ComposerPolicy {
    static func shouldSend(returnKey: Bool, command: Bool, shift: Bool, marked: Bool) -> Bool {
        returnKey && !marked && (command || !shift)
    }
}

struct MacComposer: NSViewRepresentable {
    @Binding var text: String
    var enabled: Bool
    var send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message")
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        editor.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.sendAction = send
        editor.isEditable = enabled
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposer
        init(_ parent: MacComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}
final class ComposerTextView: NSTextView {
    var sendAction: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if ComposerPolicy.shouldSend(returnKey: [36, 76].contains(event.keyCode),
                                     command: event.modifierFlags.contains(.command),
                                     shift: event.modifierFlags.contains(.shift), marked: hasMarkedText()) {
            sendAction?()
        } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), [36, 76].contains(event.keyCode), !hasMarkedText() {
            sendAction?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
