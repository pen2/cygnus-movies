import AppKit
import SwiftUI

struct LayerInspector: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor
    let layer: VisualLayer
    let width: CGFloat

    var body: some View {
        let _ = language

        VStack(alignment: .leading, spacing: 9) {
            HStack {
                LayerLabel(kind: layer.kind, title: L10n.format("%@レイヤー", layer.kind.title)).font(.headline).lineLimit(1)
                Spacer()
                Button(action: editor.duplicateLayer) { Label(L10n.text("複製"), systemImage: "plus.square.on.square") }
                    .help(L10n.text("レイヤーを複製"))
            }
            Text(L10n.text("タイムライン上の範囲（フレーム）")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                field(L10n.text("開始"), value: Binding(get: { current.start }, set: { editor.trimLayer(layer.id, start: $0) }))
                field(L10n.text("終了"), value: Binding(get: { current.end }, set: { editor.trimLayer(layer.id, end: $0) }))
            }
            Text(timecode(layer.start) + "  –  " + timecode(layer.end))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            transitionPicker(L10n.text("開始時の効果"), key: \.entrance)
            transitionPicker(L10n.text("終了時の効果"), key: \.exit)
            Divider()
            Text(L10n.text("画面内の範囲（%）")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                field(L10n.text("左"), value: percent(\.x))
                field(L10n.text("上"), value: percent(\.y))
            }
            HStack(spacing: 10) {
                field(L10n.text("幅"), value: percent(\.width))
                field(L10n.text("高さ"), value: percent(\.height))
            }
            if layer.kind == .text {
                Text(L10n.text("テキスト")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { current.text }, set: { value in
                    editor.updateLayer(layer.id) { $0.text = String(value.prefix(500)) }
                }))
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(width: width, height: 62)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                .editorHover()
                .accessibilityLabel(L10n.text("レイヤーのテキスト"))
                fontPicker
                Picker(L10n.text("揃え方"), selection: Binding(
                    get: { current.textAlignment ?? .center },
                    set: { value in editor.updateLayer(layer.id) { $0.textAlignment = value } }
                )) {
                    ForEach(LayerTextAlignment.allCases, id: \.self) { alignment in
                        Text(alignment.title).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .font(.caption)
                Toggle(L10n.text("太字"), isOn: Binding(get: { current.regularWeight != true },
                                          set: { value in editor.updateLayer(layer.id) { $0.regularWeight = value ? nil : true } }))
                    .editorHover()
                let canvas = editor.timeline.output.size
                textMetric(L10n.text("文字サイズ"), unit: "pt", value: Binding(
                    get: { current.textPoints(in: canvas) },
                    set: { value in
                        guard value.isFinite else { return }
                        editor.updateLayer(layer.id) {
                            if $0.outlinePixels == nil { $0.outlinePixels = $0.strokePixels(in: canvas) }
                            $0.fontSizePoints = min(VisualLayer.fontSizeRange.upperBound, max(1, value))
                        }
                    }
                ), sliderRange: 1...240)
                textMetric(L10n.text("縁取り"), unit: "px", value: Binding(
                    get: { current.strokePixels(in: canvas) },
                    set: { value in
                        guard value.isFinite else { return }
                        editor.updateLayer(layer.id) {
                            $0.outlinePixels = min(VisualLayer.outlineRange.upperBound, max(0, value))
                        }
                    }
                ), sliderRange: 0...24)
                HStack {
                    colorPicker(L10n.text("文字色"), key: \.textColor, defaultColor: .white)
                    Spacer()
                    colorPicker(L10n.text("縁取り色"), key: \.outlineColor, defaultColor: .black)
                }
                Toggle(L10n.text("影を付ける"), isOn: binding(\.shadow)).editorHover()
            } else if layer.kind == .rectangle {
                colorPicker(L10n.text("塗りつぶし色"), key: \.rectangleColor, defaultColor: .rectangleDefault)
                slider(L10n.text("不透明度"), value: Binding(
                    get: { current.rectangleOpacity ?? 1 },
                    set: { value in editor.updateLayer(layer.id) { $0.rectangleOpacity = value } }
                ))
            } else if layer.kind == .image {
                if let source = editor.project.sources.first(where: { $0.id == layer.sourceID }) {
                    Text(source.name).lineLimit(1).font(.caption)
                    if !FileManager.default.fileExists(atPath: source.path) {
                        Button(L10n.text("元ファイルを再指定…")) { editor.relink(source) }.disabled(editor.loadingSources)
                    }
                }
            } else {
                slider(L10n.text("強さ"), value: binding(\.intensity))
            }
        }
    }

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies

    private var fontPicker: some View {
        let chosen = current.fontFamily
        let available = Self.fontFamilies
        let families = [nil as String?] + available.map(Optional.some)
            + (chosen.map { available.contains($0) ? [] : [Optional.some($0)] } ?? [])
        return HStack(spacing: 6) {
            Text(L10n.text("フォント")).frame(width: 60, alignment: .leading)
            InspectorPopup(selection: binding(\.fontFamily), values: families,
                           titles: families.map { $0 ?? L10n.text("システム標準") }, label: L10n.text("フォント"))
                .frame(width: width - 66, height: 25).editorHover()
        }
        .font(.caption)
    }

    private var current: VisualLayer {
        editor.timeline.layers.first { $0.id == layer.id } ?? layer
    }

    private func binding<T>(_ key: WritableKeyPath<VisualLayer, T>) -> Binding<T> {
        Binding(get: { current[keyPath: key] },
                set: { value in editor.updateLayer(layer.id) { $0[keyPath: key] = value } })
    }

    private func percent(_ key: WritableKeyPath<CanvasRegion, Double>) -> Binding<Int> {
        Binding(get: { Int((current.region[keyPath: key] * 100).rounded()) },
                set: { value in editor.updateLayer(layer.id) { $0.region[keyPath: key] = Double(value) / 100 } })
    }

    private func transitionPicker(_ title: String, key: WritableKeyPath<VisualLayer, Transition?>) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 82, alignment: .leading)
            InspectorPopup(selection: Binding(
                get: { current[keyPath: key] ?? .cut },
                set: { value in
                    editor.updateLayer(layer.id) {
                        $0[keyPath: key] = value == .cut ? nil : value
                        $0.animationSpan = nil
                    }
                }
            ), values: Transition.allCases, titles: Transition.allCases.map(\.title), label: title)
            .frame(width: width - 88, height: 25).editorHover()
        }
        .font(.caption)
    }

    private func field(_ label: String, value: Binding<Int>) -> some View {
        let labelWidth: CGFloat = language.resolved == .english ? 41 : 28
        return HStack(spacing: 5) {
            Text(label).lineLimit(1).frame(width: labelWidth, alignment: .leading)
            TextField(label, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: (width - 10) / 2 - labelWidth - 5).editorHover()
                .accessibilityLabel(label)
        }
        .font(.caption.monospacedDigit())
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.01)
                .frame(width: width - 106).accessibilityLabel(label).editorHover()
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
    }

    private func textMetric(_ label: String, unit: String, value: Binding<Double>,
                            sliderRange: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { min(sliderRange.upperBound, max(sliderRange.lowerBound, value.wrappedValue)) },
                                  set: { value.wrappedValue = $0 }), in: sliderRange, step: 0.25)
                .accessibilityLabel(label)
                .editorHoverBrightness()
            TextField(label, value: value, format: .number.grouping(.never).precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .accessibilityLabel("\(label)（\(unit)）")
            Text(unit).foregroundStyle(.secondary).frame(width: 15, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
    }

    private func colorPicker(_ title: String, key: WritableKeyPath<VisualLayer, LayerColor?>,
                             defaultColor: LayerColor) -> some View {
        ColorPicker(title, selection: Binding(
            get: {
                let color = current[keyPath: key] ?? defaultColor
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
            },
            set: { selection in
                guard let color = NSColor(selection).usingColorSpace(.sRGB) else { return }
                let value = LayerColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
                guard value.isValid else { return }
                editor.updateLayer(layer.id) { $0[keyPath: key] = value }
            }
        ), supportsOpacity: false)
        .font(.caption)
    }
}

struct LayerLabel: View {
    let kind: LayerKind
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            LayerIcon(kind: kind).fixedSize()
            Text(title)
        }
    }
}

struct LayerIcon: View {
    let kind: LayerKind

    var body: some View {
        if kind == .text {
            Image(nsImage: Self.latinTextIcon).renderingMode(.original)
        } else {
            Image(systemName: kind.symbol)
        }
    }

    private static let latinTextIcon: NSImage = {
        let icon = NSImage(size: NSSize(width: 16, height: 14), flipped: true) { bounds in
            let letters = NSAttributedString(string: "Aa", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.43, green: 0.85, blue: 0.81, alpha: 1)
            ])
            let size = letters.size()
            letters.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return true
        }
        return icon
    }()
}

struct LayerRegionGuide: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    let layer: VisualLayer
    let editor: Editor
    @GestureState private var moving = CGSize.zero
    @GestureState private var resizing = CGSize.zero

    var body: some View {
        let _ = language

        GeometryReader { geometry in
            let size = geometry.size
            let region = adjusted(by: moving, sizing: resizing, in: size)
            let box = region.pixels(in: size)
            if size.width > 0 && size.height > 0 {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(.mint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .contentShape(Rectangle())
                        .frame(width: box.width, height: box.height)
                        .editorHover(radius: 0)
                        .offset(x: box.minX, y: box.minY)
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .updating($moving) { value, state, _ in state = value.translation }
                                .onChanged { value in
                                    editor.previewLayerRegion(layer.id, region: adjusted(by: value.translation, sizing: .zero, in: size))
                                }
                                .onEnded { value in commit(adjusted(by: value.translation, sizing: .zero, in: size)) }
                        )
                    Circle()
                        .fill(.mint)
                        .frame(width: 10, height: 10)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .editorHover(radius: 10)
                        .position(x: box.maxX, y: box.maxY)
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .updating($resizing) { value, state, _ in state = value.translation }
                                .onChanged { value in
                                    editor.previewLayerRegion(layer.id, region: adjusted(by: .zero, sizing: value.translation, in: size))
                                }
                                .onEnded { value in commit(adjusted(by: .zero, sizing: value.translation, in: size)) }
                        )
                }
                .help(L10n.text("枠をドラッグして移動、右下の丸でサイズを変更"))
            }
        }
        .onChange(of: moving != .zero || resizing != .zero) { dragging in
            if !dragging {
                // Give onEnded the first chance to commit; a cancelled gesture has no onEnded.
                Task { @MainActor in
                    if moving == .zero && resizing == .zero { editor.cancelLayerPreview(layer.id) }
                }
            }
        }
        .onDisappear { editor.cancelLayerPreview(layer.id) }
        .accessibilityHidden(true)
    }

    private func adjusted(by offset: CGSize, sizing delta: CGSize, in size: CGSize) -> CanvasRegion {
        guard size.width > 0, size.height > 0 else { return layer.region }
        var region = layer.region
        region.x += offset.width / size.width
        region.y += offset.height / size.height
        region.width = min(1 - layer.region.x, region.width + delta.width / size.width)
        region.height = min(1 - layer.region.y, region.height + delta.height / size.height)
        return region.contained()
    }

    private func commit(_ region: CanvasRegion) {
        editor.commitLayerRegion(layer.id, region: region)
    }
}
