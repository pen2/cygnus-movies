import SwiftUI
import UniformTypeIdentifiers

struct TimelineTrack: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    @AppStorage(TimelinePreferences.waveform) private var showWaveform = false

    @ObservedObject var editor: Editor
    let zoom: Double
    let fittedFrames: Int?
    let snapping: Bool
    let layerHeight: CGFloat
    let tabFrames: [UUID: CGRect]
    @Binding var tabDropTarget: UUID?
    @Binding var dragAvatar: TimelineDragAvatar?
    static let layerRowHeight: CGFloat = 24

    @State private var peaks: [Float]?
    @State private var waveformError: String?
    @State private var insertion: ClipInsertion?
    @State private var finishingDrop = false
    @State private var activeDrag: Editor.ItemTransfer?
    @State private var moveGuide: TimelineSnap.Adjustment?
    @State private var draggedOffset: CGFloat?
    @State private var trackFrame = CGRect.null
    @State private var viewportFrame = CGRect.null
    private let inset = TimelineScale.inset
    private let chunkWidth = 800.0

    private struct WaveformRequest: Equatable {
        let timelineID: UUID
        let clips: [Clip]
        let sources: [Source]
        let frames: Int
    }

    var body: some View {
        let _ = language

        let request = showWaveform && !editor.timeline.clips.isEmpty
            ? WaveformRequest(timelineID: editor.timeline.id, clips: editor.timeline.clips, sources: editor.project.sources,
                              frames: editor.totalFrames)
            : nil
        GeometryReader { geometry in
            let scale = TimelineScale(width: geometry.size.width)
            let pointsPerSecond = scale.pointsPerSecond(zoom: zoom, fittedFrames: fittedFrames)
            let pointsPerFrame = pointsPerSecond / 30
            let durationWidth = Double(editor.totalFrames) * pointsPerFrame
            let width = max(geometry.size.width, durationWidth + 2 * inset + (fittedFrames == nil ? 120 : 24))
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ruler(width, pointsPerSecond: pointsPerSecond)
                    if layerHeight > 0 {
                        layerTracks(width, height: layerHeight, pointsPerFrame: pointsPerFrame)
                    }
                    clips(width, pointsPerFrame: pointsPerFrame)
                    if showWaveform {
                        waveformLane(width, durationWidth: durationWidth)
                    }
                }
                .background(alignment: .topLeading) { TimelineWheel().frame(width: 0, height: 0) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineScale.editorSpace)) } action: {
                    trackFrame = $0
                }
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10))
                        Rectangle().frame(width: 1, height: (showWaveform ? 132 : 92) + layerHeight)
                    }
                    .foregroundStyle(Color(red: 0.45, green: 0.92, blue: 0.86))
                    .offset(x: inset + Double(editor.playhead) * pointsPerFrame - 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    if let moveGuide {
                        TimelineDragLine(snapped: moveGuide.snapped, height: layerHeight + 76)
                            .offset(x: inset + Double(moveGuide.guide) * pointsPerFrame - 1, y: 27)
                    }
                }
            }
            .id(editor.timeline.id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineScale.editorSpace)) } action: {
                viewportFrame = $0
            }
        }
        .onChange(of: editor.timeline.id) { _ in
            insertion = nil
            finishingDrop = false
            cancelItemDrag()
        }
        .onChange(of: editor.timeline.clips.map(\.id)) { _ in insertion = nil }
        .task(id: insertion != nil) {
            guard insertion != nil else { return }
            // A cancelled system drag does not always call dropExited.
            while NSEvent.pressedMouseButtons != 0 {
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            finishingDrop = true
            insertion = nil
        }
        .task(id: request) {
            peaks = nil
            waveformError = nil
            guard let request else { return }
            let timeline = editor.timeline
            do {
                try await Task.sleep(for: .milliseconds(250))
                let data = try await waveform(timeline, sources: request.sources)
                try Task.checkCancellation()
                peaks = data
            } catch {
                guard !Task.isCancelled else { return }
                waveformError = L10n.text("音声波形を表示できません")
            }
        }
    }

    private func ruler(_ width: Double, pointsPerSecond: Double) -> some View {
        let steps = [1.0 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let interval = steps.first { $0 * pointsPerSecond >= 48 } ?? 600
        return chunks(width, height: 27) { context, size, offset in
            let first = max(0, Int(ceil((offset - inset) / (interval * pointsPerSecond))))
            let last = Int((offset + size.width - inset) / (interval * pointsPerSecond))
            guard first <= last else { return }
            var ticks = Path()
            for index in first...last {
                let seconds = Double(index) * interval
                let x = inset + seconds * pointsPerSecond - offset
                ticks.move(to: CGPoint(x: x, y: 18))
                ticks.addLine(to: CGPoint(x: x, y: size.height))
                let frames = Int((seconds * 30).rounded())
                let label = interval >= 1
                    ? String(format: "%02d:%02d", frames / 1800, (frames / 30) % 60)
                    : String(format: "%02d:%02d:%02d", frames / 1800, (frames / 30) % 60, frames % 30)
                context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 11), anchor: .leading)
            }
            context.stroke(ticks, with: .color(.white.opacity(0.24)), lineWidth: 1)
        }
        .background(.white.opacity(0.035))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            editor.seek(Int(((value.location.x - inset) * 30 / pointsPerSecond).rounded()))
        })
        .accessibilityLabel(L10n.text("タイムルーラー"))
        .accessibilityValue(timecode(editor.playhead))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: editor.seek(editor.playhead + 1)
            case .decrement: editor.seek(editor.playhead - 1)
            @unknown default: break
            }
        }
    }

    private func waveformLane(_ width: Double, durationWidth: Double) -> some View {
        ZStack(alignment: .leading) {
            chunks(width, height: 40) { context, size, offset in
                guard let peaks, !peaks.isEmpty, durationWidth > 0 else { return }
                let start = max(0, Int(floor(inset - offset)))
                let end = min(Int(ceil(size.width)), Int(ceil(inset + durationWidth - offset)))
                guard end > start else { return }
                let midpoint = size.height / 2
                var trace = Path()
                for pixel in start..<end {
                    let left = (offset + Double(pixel) - inset) / durationWidth
                    let right = (offset + Double(pixel + 1) - inset) / durationWidth
                    let first = min(peaks.count - 1, max(0, Int(left * Double(peaks.count))))
                    let last = min(peaks.count - 1, max(first, Int(ceil(right * Double(peaks.count))) - 1))
                    let height = max(0.5, Double(peaks[first...last].max() ?? 0) * (midpoint - 2))
                    let x = CGFloat(pixel) + 0.5
                    trace.move(to: CGPoint(x: x, y: midpoint - height))
                    trace.addLine(to: CGPoint(x: x, y: midpoint + height))
                }
                context.stroke(trace, with: .color(.mint.opacity(0.8)), lineWidth: 1)
            }
            if !editor.timeline.clips.isEmpty, peaks == nil {
                Text(waveformError ?? L10n.text("音声波形を読み込み中…"))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, inset)
            }
        }
        .background(.black.opacity(0.3))
        .accessibilityLabel(L10n.text("音声波形"))
    }

    private func chunks(
        _ width: Double, height: Double,
        draw: @escaping (GraphicsContext, CGSize, Double) -> Void
    ) -> some View {
        LazyHStack(spacing: 0) {
            ForEach(0..<Int(ceil(width / chunkWidth)), id: \.self) { index in
                let offset = Double(index) * chunkWidth
                Canvas { context, size in
                    draw(context, size, offset)
                }
                .frame(width: min(chunkWidth, width - offset), height: height)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    private func layerTracks(_ width: Double, height: Double, pointsPerFrame: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(editor.timeline.layers.reversed())) { layer in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.025))
                            LayerBlock(editor: editor, layer: layer, pointsPerFrame: pointsPerFrame, snapping: snapping,
                                       move: dragModifier(for: .layer(layer.id), pointsPerFrame: pointsPerFrame))
                                .opacity(dragOpacity(.layer(layer.id)))
                                .offset(x: inset + Double(layer.start) * pointsPerFrame + dragOffset(.layer(layer.id)))
                        }
                        .frame(width: width, height: Self.layerRowHeight)
                        .overlay(alignment: .bottom) { Divider() }
                        .id(layer.id)
                    }
                }
            }
            .frame(width: width, height: height)
            .onChange(of: editor.layerID) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func clips(_ width: Double, pointsPerFrame: Double) -> some View {
        let placements = editor.placements
        let slots = placements.enumerated().map { ClipInsertion(index: $0.offset, frame: $0.element.start) }
            + [ClipInsertion(index: placements.count, frame: editor.clipFrames)]
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.2))

            if placements.isEmpty {
                Label(L10n.text("素材をここにドラッグ"), systemImage: "rectangle.dashed")
                    .font(.callout).foregroundStyle(.secondary).padding(17)
                    .allowsHitTesting(false)
            }

            ForEach(placements, id: \.clip.id) { placement in
                ClipBlock(editor: editor, placement: placement, pointsPerFrame: pointsPerFrame, snapping: snapping,
                          move: dragModifier(for: .clip(placement.clip.id), pointsPerFrame: pointsPerFrame))
                    .opacity(dragOpacity(.clip(placement.clip.id)))
                    .offset(x: inset + Double(placement.start) * pointsPerFrame + dragOffset(.clip(placement.clip.id)), y: 8)
                    .zIndex(isDragging(.clip(placement.clip.id)) ? 3 : editor.selections.contains(.clip(placement.clip.id)) ? 2 : 1)
            }
        }
        .frame(width: width, height: 76)
        .contentShape(Rectangle())
        .onDrop(of: [TimelineDrag.contentType], delegate: ClipLaneDrop(
            editor: editor, timelineID: editor.timeline.id, slots: slots, pointsPerFrame: pointsPerFrame,
            insertion: $insertion, finishingDrop: $finishingDrop
        ))
        .overlay(alignment: .topLeading) {
            if let insertion {
                TimelineDragLine(snapped: true, height: 74)
                    .offset(x: inset + Double(insertion.frame) * pointsPerFrame - 1)
            }
        }
    }

    private func cancelItemDrag() {
        activeDrag = nil
        moveGuide = nil
        draggedOffset = nil
        tabDropTarget = nil
        dragAvatar = nil
    }

    private func isDragging(_ item: Editor.Selection) -> Bool { activeDrag?.items.contains(item) == true }

    private func dragOffset(_ item: Editor.Selection) -> CGFloat {
        isDragging(item) ? draggedOffset ?? 0 : 0
    }

    private func dragOpacity(_ item: Editor.Selection) -> Double {
        guard isDragging(item) else { return 1 }
        return draggedOffset == nil ? 0.32 : 0.68
    }

    private func dragModifier(for item: Editor.Selection, pointsPerFrame: Double) -> TimelineBlockDrag {
        TimelineBlockDrag(item: item, change: { item, value, finished in
            itemDrag(item, value, finished: finished, pointsPerFrame: pointsPerFrame)
        }, select: { extending in
            switch item {
            case let .clip(id): editor.selectClip(id, extending: extending)
            case let .layer(id): editor.selectLayer(id, extending: extending)
            case .source: break
            }
        }, cancel: cancelItemDrag)
    }

    private func itemDrag(_ item: Editor.Selection, _ value: DragGesture.Value, finished: Bool,
                          pointsPerFrame: Double) {
        let transfer = activeDrag ?? editor.beginItemDrag(item)
        let tab = targetTab(near: value.location, excluding: transfer.origin)
        let target = tab == nil ? localTarget(for: transfer, item: item, value: value, pointsPerFrame: pointsPerFrame) : nil
        let copy = NSEvent.modifierFlags.contains(.option) || NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if finished {
            defer { cancelItemDrag() }
            if let tab {
                editor.placeItems(transfer, in: tab, copy: copy)
            } else if let target {
                editor.placeItems(transfer, in: transfer.origin, insertion: target.index, frame: target.guide.guide, copy: copy)
            }
        } else {
            activeDrag = transfer
            tabDropTarget = tab
            moveGuide = target?.guide
            draggedOffset = target.map {
                $0.index == nil ? Double($0.guide.delta) * pointsPerFrame : value.translation.width
            }
            dragAvatar = target == nil ? avatar(for: item, transfer: transfer, location: value.location, copy: copy) : nil
        }
    }

    private func targetTab(near point: CGPoint, excluding origin: UUID) -> UUID? {
        if tabFrames[origin]?.contains(point) == true { return nil }
        let candidates = tabFrames.filter { id, rect in
            id != origin && !rect.isEmpty && rect.insetBy(dx: -7, dy: -10).contains(point)
        }
        return candidates.min { first, second in
            func distance(_ rect: CGRect) -> CGFloat {
                rect.contains(point) ? 0 : hypot(rect.midX - point.x, rect.midY - point.y)
            }
            return distance(first.value) < distance(second.value)
        }?.key
    }

    private func avatar(for item: Editor.Selection, transfer: Editor.ItemTransfer, location: CGPoint,
                        copy: Bool) -> TimelineDragAvatar? {
        switch item {
        case let .clip(id):
            guard let clip = editor.timeline.clips.first(where: { $0.id == id }) else { return nil }
            let source = editor.project.sources.first { $0.id == clip.sourceID }
            return TimelineDragAvatar(location: location, title: editor.name(of: clip), symbol: "film",
                                      source: source, frame: clip.start, count: transfer.items.count, copying: copy)
        case let .layer(id):
            guard let layer = editor.timeline.layers.first(where: { $0.id == id }) else { return nil }
            let source = editor.project.sources.first { $0.id == layer.sourceID }
            return TimelineDragAvatar(location: location, title: source?.name ?? layer.title, symbol: layer.kind.symbol,
                                      source: source, frame: 0, count: transfer.items.count, copying: copy)
        case .source: return nil
        }
    }

    private func localTarget(for transfer: Editor.ItemTransfer, item: Editor.Selection, value: DragGesture.Value,
                             pointsPerFrame: Double) -> (guide: TimelineSnap.Adjustment, index: Int?)? {
        let rows = CGRect(x: trackFrame.minX, y: trackFrame.minY + 27,
                          width: trackFrame.width, height: layerHeight + 76)
        guard rows.intersection(viewportFrame).contains(value.location) else { return nil }
        let clips = editor.placements
        if let firstClip = clips.first(where: { transfer.items.contains(.clip($0.clip.id)) }) {
            let proposed: Double
            if case .layer = item {
                proposed = Double(firstClip.start) + value.translation.width / pointsPerFrame
            } else {
                proposed = (value.location.x - trackFrame.minX - inset) / pointsPerFrame
            }
            let slots = clips.map(\.start) + [editor.clipFrames]
            guard let index = slots.indices.min(by: { abs(Double(slots[$0]) - proposed) < abs(Double(slots[$1]) - proposed) })
            else { return nil }
            return (.init(delta: 0, guide: slots[index], snapped: true), index)
        }

        let selected = editor.timeline.layers.filter { transfer.items.contains(.layer($0.id)) }
        guard let start = selected.map(\.start).min(), let end = selected.map(\.end).max() else { return nil }
        let neighbors = editor.timeline.layers.filter { !transfer.items.contains(.layer($0.id)) }
        let targets = clips.flatMap { [$0.start, $0.end] } + neighbors.flatMap { [$0.start, $0.end] }
        let snap = TimelineSnap(pointsPerFrame: pointsPerFrame, targets: snapping ? targets : [])
        let adjusted = snap.adjust(translation: value.translation.width, edges: selected.flatMap { [$0.start, $0.end] },
                                   limits: (-start)...(VisualLayer.maximumEnd - end))
        return (.init(delta: adjusted.delta, guide: start + adjusted.delta, snapped: adjusted.snapped), nil)
    }
}

private struct ClipInsertion: Equatable {
    let index: Int
    let frame: Int
}

private struct ClipLaneDrop: DropDelegate {
    let editor: Editor
    let timelineID: UUID
    let slots: [ClipInsertion]
    let pointsPerFrame: Double
    @Binding var insertion: ClipInsertion?
    @Binding var finishingDrop: Bool

    private func target(at point: CGPoint) -> ClipInsertion {
        let frame = (point.x - TimelineScale.inset) / pointsPerFrame
        return slots.min(by: { abs(Double($0.frame) - frame) < abs(Double($1.frame) - frame) }) ?? .init(index: 0, frame: 0)
    }

    func dropEntered(info: DropInfo) {
        finishingDrop = false
        insertion = target(at: info.location)
    }
    func dropExited(info: DropInfo) { insertion = nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !finishingDrop { insertion = target(at: info.location) }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let slot = target(at: info.location)
        finishingDrop = true
        insertion = nil
        guard let provider = info.itemProviders(for: [TimelineDrag.contentType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: TimelineDrag.contentType.identifier) { data, _ in
            Task { @MainActor in
                guard editor.timeline.id == timelineID else { return }
                defer { insertion = nil }
                guard let data, let payload = String(data: data, encoding: .utf8) else { return }
                _ = editor.drop(payload, at: min(slot.index, editor.timeline.clips.count))
            }
        }
        return true
    }
}

private struct TimelineDragLine: View {
    let snapped: Bool
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(snapped ? Color(red: 1, green: 0.73, blue: 0.34) : .white.opacity(0.76))
            .frame(width: snapped ? 3 : 2, height: height)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
private func snapTargets(_ editor: Editor, excludingClip clip: UUID? = nil, adjacentTo layer: UUID? = nil) -> [Int] {
    let video = editor.placements.filter { $0.clip.id != clip }.flatMap { [$0.start, $0.end] }
    let layers = editor.timeline.layers
    let neighbors: [VisualLayer]
    if let layer, let index = layers.firstIndex(where: { $0.id == layer }) {
        neighbors = [index - 1, index + 1].filter(layers.indices.contains).map { layers[$0] }
    } else {
        neighbors = Array(layers.prefix(1))
    }
    return video + neighbors.flatMap { [$0.start, $0.end] }
}

private struct ClipBlock: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor
    let placement: Placement
    let pointsPerFrame: Double
    let snapping: Bool
    let move: TimelineBlockDrag
    @GestureState private var leadingTrim: TimelineSnap.Adjustment?
    @GestureState private var trailingTrim: TimelineSnap.Adjustment?

    private var leadingDelta: Int { leadingTrim?.delta ?? 0 }
    private var trailingDelta: Int { trailingTrim?.delta ?? 0 }

    private var clip: Clip { placement.clip }
    private var selected: Bool { editor.selections.contains(.clip(clip.id)) }
    private var width: Double { max(2, Double(clip.length + trailingDelta - leadingDelta) * pointsPerFrame) }

    var body: some View {
        let _ = language

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color(red: 0.15, green: 0.41, blue: 0.41) : Color(red: 0.15, green: 0.28, blue: 0.36))
            if width >= 25 {
                HStack(spacing: 7) {
                    if width >= 130,
                       let source = editor.project.sources.first(where: { $0.id == clip.sourceID }) {
                        SourceThumbnail(source: source, missing: !FileManager.default.fileExists(atPath: source.path),
                                        frame: clip.start)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(editor.name(of: clip)).font(.caption.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(timecode(clip.length + trailingDelta - leadingDelta)).monospacedDigit()
                            if clip.fadeIn || clip.fadeOut { Image(systemName: "circle.lefthalf.filled") }
                            if placement.overlapAfter > 0 { Image(systemName: "square.on.square") }
                        }
                        .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(width: width, height: 58)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.mint : .white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .editorHover()
        .modifier(move)
        .overlay {
            if selected && width >= 16 {
                HStack(spacing: 0) {
                    handle(leading: true)
                    Spacer(minLength: 0)
                    handle(leading: false)
                }
            }
        }
        .overlay(alignment: .leading) {
            if let leadingTrim { TimelineDragLine(snapped: leadingTrim.snapped, height: 64) }
        }
        .overlay(alignment: .trailing) {
            if let trailingTrim { TimelineDragLine(snapped: trailingTrim.snapped, height: 64) }
        }
        .offset(x: Double(leadingDelta) * pointsPerFrame)
        .contextMenu {
            Button(L10n.text("クリップの先頭へ移動")) {
                editor.selectClip(clip.id)
                editor.seek(placement.start)
            }
            Button(L10n.text("クリップを複製")) { editor.duplicateClip(clip.id) }
            TimelineTransferMenus(editor: editor, item: .clip(clip.id))
            Divider()
            Button(selected && editor.selections.count > 1 ? L10n.text("選択した項目を削除") : L10n.text("クリップを削除"),
                   role: .destructive) { editor.removeClip(clip.id) }
        }
        .buttonStyle(.automatic)
        .help(editor.name(of: clip))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.selectClip(clip.id) }
    }

    private func handle(leading: Bool) -> some View {
        let enabled = hasTrimRoom(trimLimits(leading: leading))
        return TrimGrip(height: 58, lineHeight: 16, enabled: enabled)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating(leading ? $leadingTrim : $trailingTrim) { value, state, _ in
                        state = trim(value.translation.width, leading: leading)
                    }
                    .onEnded { value in
                        let change = trim(value.translation.width, leading: leading).delta
                        editor.trimTimeline(clip.id, leading: leading, delta: change)
                    }
            )
            .allowsHitTesting(enabled)
            .help(leading ? L10n.text("開始位置をトリミング") : L10n.text("終了位置をトリミング"))
    }

    private func trimLimits(leading: Bool) -> ClosedRange<Int> {
        let sourceEnd = editor.project.sources.first { $0.id == clip.sourceID }?.frames ?? clip.end
        let rate = clip.sourceFramesPerTimelineFrame
        return leading ? Int(ceil(-clip.sourceStart / rate))...(clip.length - 1)
            : (1 - clip.length)...Int(floor((Double(sourceEnd) - clip.sourceEnd) / rate))
    }

    private func trim(_ translation: Double, leading: Bool) -> TimelineSnap.Adjustment {
        TimelineSnap(pointsPerFrame: pointsPerFrame,
                     targets: snapping ? snapTargets(editor, excludingClip: clip.id) : [])
            .adjust(translation: translation, edges: [leading ? placement.start : placement.end],
                    limits: trimLimits(leading: leading))
    }
}

private struct LayerBlock: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor
    let layer: VisualLayer
    let pointsPerFrame: Double
    let snapping: Bool
    let move: TimelineBlockDrag
    @GestureState private var startTrim: TimelineSnap.Adjustment?
    @GestureState private var endTrim: TimelineSnap.Adjustment?

    private var startDelta: Int { startTrim?.delta ?? 0 }
    private var endDelta: Int { endTrim?.delta ?? 0 }
    private var selected: Bool { editor.selections.contains(.layer(layer.id)) }
    private var length: Int { layer.end - layer.start }
    private var width: Double { max(selected ? 22 : 8, Double(length - startDelta + endDelta) * pointsPerFrame) }
    private var color: Color {
        switch layer.kind {
        case .text: .purple
        case .rectangle: .pink
        case .image: .teal

        case .blur: .blue
        case .mosaic: .orange
        }
    }

    var body: some View {
        let _ = language

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(color.opacity(selected ? 0.65 : 0.36))
            if width >= 27 {
                LayerLabel(kind: layer.kind, title: layerTitle)
                    .font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, 5)
            }
        }
        .frame(width: width, height: 20)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? .mint : .white.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .editorHover(radius: 4)
        .modifier(move)
        .overlay {
            if selected && width >= 18 {
                HStack(spacing: 0) {
                    trimHandle(start: true)
                    Spacer(minLength: 0)
                    trimHandle(start: false)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let guide = startTrim ?? endTrim {
                let start = layer.start + startDelta
                TimelineDragLine(snapped: guide.snapped, height: 24)
                    .offset(x: Double(guide.guide - start) * pointsPerFrame - 1, y: -2)
            }
        }
        .offset(x: Double(startDelta) * pointsPerFrame)
        .contextMenu {
            Button(L10n.text("レイヤーの先頭へ移動")) {
                editor.selectLayer(layer.id)
                editor.seek(layer.start)
            }
            Button(L10n.text("レイヤーを複製")) { editor.duplicateLayer(layer.id) }
            TimelineTransferMenus(editor: editor, item: .layer(layer.id))
            Button(L10n.text("前面へ移動")) { editor.reorderLayer(by: 1, id: layer.id) }
                .disabled(!editor.canReorderLayer(by: 1, id: layer.id))
            Button(L10n.text("背面へ移動")) { editor.reorderLayer(by: -1, id: layer.id) }
                .disabled(!editor.canReorderLayer(by: -1, id: layer.id))
            Divider()
            Button(selected && editor.selections.count > 1 ? L10n.text("選択した項目を削除") : L10n.text("レイヤーを削除"),
                   role: .destructive) { editor.removeLayer(layer.id) }
        }
        .buttonStyle(.automatic)
        .help(layerTitle + "  " + timecode(layer.start) + " – " + timecode(layer.end))
        .accessibilityLabel(layerTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.selectLayer(layer.id) }
    }

    private var layerTitle: String {
        if let id = layer.sourceID, let source = editor.project.sources.first(where: { $0.id == id }) { return source.name }
        return layer.title
    }

    private func trimHandle(start: Bool) -> some View {
        let enabled = hasTrimRoom(trimLimits(start: start))
        return TrimGrip(height: 20, lineHeight: 11, enabled: enabled)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating(start ? $startTrim : $endTrim) { value, state, _ in
                        state = trim(value, start: start)
                    }
                    .onEnded { value in
                        let amount = trim(value, start: start).delta
                        if start { editor.trimLayer(layer.id, start: layer.start + amount) }
                        else { editor.trimLayer(layer.id, end: layer.end + amount) }
                    }
            )
            .allowsHitTesting(enabled)
            .help(start ? L10n.text("レイヤーの開始位置を調整") : L10n.text("レイヤーの終了位置を調整"))
    }

    private var snap: TimelineSnap {
        TimelineSnap(pointsPerFrame: pointsPerFrame, targets: snapping ? snapTargets(editor, adjacentTo: layer.id) : [])
    }

    private func trimLimits(start: Bool) -> ClosedRange<Int> {
        start ? (-layer.start)...(length - 1) : (1 - length)...(VisualLayer.maximumEnd - layer.end)
    }

    private func trim(_ value: DragGesture.Value, start: Bool) -> TimelineSnap.Adjustment {
        snap.adjust(translation: value.translation.width, edges: [start ? layer.start : layer.end],
                    limits: trimLimits(start: start))
    }
}

private struct TimelineBlockDrag: ViewModifier {
    let item: Editor.Selection
    let change: (Editor.Selection, DragGesture.Value, Bool) -> Void
    let select: (Bool) -> Void
    let cancel: () -> Void
    @GestureState private var interacting = false
    @State private var moved = false

    func body(content: Content) -> some View {
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineScale.editorSpace))
        content
            .gesture(interaction(drag.modifiers(.shift), extending: true)
                .exclusively(before: interaction(drag, extending: false)))
            .onChange(of: interacting) { active in
                if !active {
                    Task { @MainActor in
                        guard !interacting, moved else { return }
                        moved = false
                        cancel()
                    }
                }
            }
    }

    private func interaction<G: Gesture>(_ gesture: G, extending: Bool) -> some Gesture
    where G.Value == DragGesture.Value {
        gesture
            .updating($interacting) { _, state, _ in state = true }
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if moved || distance >= 5 {
                    moved = true
                    change(item, value, false)
                }
            }
            .onEnded { value in
                if moved { change(item, value, true) }
                else { select(extending) }
                moved = false
            }
    }
}

private struct TimelineTransferMenus: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor
    let item: Editor.Selection

    var body: some View {
        let _ = language

        let destinations = editor.project.timelines.filter { $0.id != editor.timeline.id }
        if !destinations.isEmpty {
            menu(L10n.text("他のタイムラインへ移動"), destinations: destinations, copy: false)
            menu(L10n.text("他のタイムラインへ複製"), destinations: destinations, copy: true)
        }
        Button(L10n.text("新しいタイムラインを作成して移動")) {
            editor.placeItemsInNewTimeline(editor.itemsForTransfer(item), copy: false)
        }
        Button(L10n.text("新しいタイムラインを作成して複製")) {
            editor.placeItemsInNewTimeline(editor.itemsForTransfer(item), copy: true)
        }
    }

    private func menu(_ title: String, destinations: [Timeline], copy: Bool) -> some View {
        Menu(title) {
            ForEach(destinations) { timeline in
                Button(editor.timelineDisplayName(timeline)) {
                    editor.placeItems(editor.itemsForTransfer(item), in: timeline.id, copy: copy)
                }
            }
        }
    }
}

private func hasTrimRoom(_ limits: ClosedRange<Int>) -> Bool {
    limits.lowerBound != limits.upperBound
}

private struct TrimGrip: View {
    let height: CGFloat
    let lineHeight: CGFloat
    let enabled: Bool
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(enabled && hovering ? .orange : .white.opacity(enabled ? 0.8 : 0.3))
            .frame(width: 2, height: lineHeight)
            .frame(width: 8, height: height)
            .contentShape(Rectangle())
            .background { TrimCursor(enabled: enabled) }
            .onHover { inside in
                hovering = inside
                if enabled { (inside ? NSCursor.resizeLeftRight : .arrow).set() }
            }
            .onDisappear {
                if enabled && hovering { NSCursor.arrow.set() }
            }
    }
}
