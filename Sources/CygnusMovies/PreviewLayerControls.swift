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
                if selected || layer.kind == .rectangle || layer.kind == .text {
                    let path = hitPath(layer, box)
                    if editor.editingTextID == layer.id && selected {
                        InlineLayerText(editor: editor, layer: layer)
                            .frame(width: min(canvas.width, max(96, box.width)),
                                   height: min(canvas.height, max(64, box.height)))
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
                        .simultaneousGesture(TapGesture(count: 2).onEnded { editor.beginInlineEditing(layer.id) })
                        .simultaneousGesture(TapGesture().onEnded { editor.selectLayer(layer.id) })
                        .contextMenu { LayerActions(editor: editor, layer: layer) }
                    }
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
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextEditor(text: Binding(get: { layer.text }, set: { value in
                editor.updateLayer(layer.id) { $0.text = String(value.prefix(500)) }
            }))
            .focused($focused)
            Button(L10n.text("完了")) { editor.editingTextID = nil }.controlSize(.small)
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .onAppear { focused = true }
        .onExitCommand { editor.editingTextID = nil }
    }
}
