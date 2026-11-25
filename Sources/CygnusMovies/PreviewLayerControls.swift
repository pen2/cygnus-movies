import SwiftUI

struct PreviewLayerControls: View {
    @ObservedObject var editor: Editor
    let canvas: CGSize
    let scale: CGFloat

    @State private var hoverID: UUID?

    var body: some View {
        let frame = min(editor.playhead, max(0, editor.totalFrames - 1))
        ZStack(alignment: .topLeading) {
            ForEach(editor.timeline.layers.filter { $0.sound == nil && ($0.start..<$0.end).contains(frame) }) { layer in
                let selected = editor.layerID == layer.id
                let box = layer.region.pixels(in: canvas)
                let path = hitPath(layer, box)
                if editor.editingTextID == layer.id && selected {
                    InlineLayerText(editor: editor, layer: layer)
                        .frame(width: min(canvas.width, max(96, box.width)),
                               height: min(canvas.height, min(160, 80 + CGFloat(layer.text.filter { $0 == "\n" }.count) * 18)))
                        .position(x: box.midX, y: box.midY)
                        .zIndex(1)
                } else {
                    ZStack(alignment: .topLeading) {
                        path.fill(hoverID == layer.id ? Color.mint.opacity(0.10) : .clear)
                            .contentShape(path)
                            .onHover { inside in
                                if inside { hoverID = layer.id }
                                else if hoverID == layer.id { hoverID = nil }
                            }
                        if selected {
                            if layer.usesEndpoints, let effects = MovieExtensions.effects {
                                effects.guide(shape: layer.artworkID, parameters: Binding(
                                    get: { layer.editableParameters },
                                    set: { value in editor.updateLayer(layer.id) { $0.setEditableParameters(value) } }
                                ), frame: CGRect(origin: .zero, size: canvas), canvas: canvas, scale: scale)
                            } else {
                                LayerRegionGuide(layer: layer, editor: editor)
                            }
                        }
                    }
                    .contentShape(interactionPath(path, layer: layer, box: box, selected: selected))
                    .simultaneousGesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { tap in
                        if case .first = tap, layer.kind == .text {
                            editor.beginInlineEditing(layer.id)
                        } else {
                            editor.selectLayer(layer.id)
                        }
                    })
                    .contextMenu { LayerActions(editor: editor, layer: layer) }
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    private func hitPath(_ layer: VisualLayer, _ box: CGRect) -> Path {
        if let shape = layer.artworkID, let effects = MovieExtensions.effects {
            return effects.hitPath(shape: shape, parameters: layer.effectParameters, rect: box, scale: scale)
        }
        return Path(box)
    }

    private func interactionPath(_ path: Path, layer: VisualLayer, box: CGRect, selected: Bool) -> Path {
        guard selected else { return path }
        var region = path
        if layer.usesEndpoints {
            let values = layer.editableParameters?.values ?? [:]
            for (x, y, fallback) in [("x1", "y1", 0.0), ("x2", "y2", 1.0)] {
                region.addRect(CGRect(x: (values[x] ?? fallback) * canvas.width - 12,
                                      y: (values[y] ?? fallback) * canvas.height - 12, width: 24, height: 24))
            }
        } else {
            region.addRect(CGRect(x: box.maxX - 10, y: box.maxY - 10, width: 20, height: 20))
        }
        return region
    }
}

private struct InlineLayerText: View {
    @ObservedObject var editor: Editor
    let layer: VisualLayer
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            InlineTextInput(text: layer.text, update: { value in
                editor.updateLayer(layer.id) { $0.text = value }
            }, finish: { editor.editingTextID = nil })
            Button(L10n.text("完了")) { editor.editingTextID = nil }.controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .background(OutsideEditClick { editor.editingTextID = nil })
        .onExitCommand { editor.editingTextID = nil }
    }
}

private struct InlineTextInput: NSViewRepresentable {
    let text: String
    let update: (String) -> Void
    let finish: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: InlineTextInput
        init(_ owner: InlineTextInput) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let value = String(view.string.prefix(500))
            if value != view.string { view.string = value }
            owner.update(value)
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            owner.finish()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = false
        view.font = .systemFont(ofSize: 15)
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        view.delegate = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window, window.makeFirstResponder(view) else { return }
            view.selectAll(nil)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let view = scroll.documentView as? NSTextView, !view.hasMarkedText(), view.string != text else { return }
        view.string = text
    }
}

private struct OutsideEditClick: NSViewRepresentable {
    let finish: () -> Void
    final class Boundary: NSView {
        var finish: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                window.makeFirstResponder(nil)
                self.finish?()
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Boundary { Boundary() }
    func updateNSView(_ view: Boundary, context: Context) { view.finish = finish }
}
