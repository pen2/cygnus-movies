import AppKit
import SwiftUI

struct EditorShortcuts: NSViewRepresentable {
    let editor: Editor

    func makeNSView(context: Context) -> KeyMonitor { KeyMonitor(editor: editor) }
    func updateNSView(_ view: KeyMonitor, context: Context) { view.editor = editor }

    final class KeyMonitor: NSView {
        weak var editor: Editor?
        private var monitor: Any?

        init(editor: Editor) {
            self.editor = editor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                      let editor = self.editor else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "z", modifiers == .command || modifiers == [.command, .shift] {
                    if !event.isARepeat { editor.performHistoryCommand(redo: modifiers.contains(.shift)) }
                    return nil
                }
                guard modifiers.isEmpty,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField)
                else { return event }
                if event.keyCode == 51 || event.keyCode == 117 {
                    guard editor.selection != nil else { return event }
                    if !event.isARepeat { editor.deleteSelection() }
                    return nil
                }
                if key == "b" {
                    if !event.isARepeat { editor.split() }
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
