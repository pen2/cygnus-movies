import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Editor: ObservableObject {
    enum ExportStatus {
        case waiting, exporting, complete, canceled, failed(String)

        var title: String {
            switch self {
            case .waiting: L10n.text("待機中")
            case .exporting: L10n.text("書き出し中")
            case .complete: L10n.text("完了")
            case .canceled: L10n.text("キャンセル済み")
            case let .failed(message): L10n.format("失敗 — %@", message)
            }
        }
    }

    struct ExportJob: Identifiable {
        let id = UUID()
        let timeline: Timeline
        let destination: URL
        var progress = 0.0
        var status = ExportStatus.waiting
        var encoder: EncodingMode?
    }

    @Published private(set) var project = Project()
    @Published private var undoEdits: [Edit] = []
    @Published private var redoEdits: [Edit] = []

    private struct EditState {
        let project: Project
        let timelineID: UUID
        let selections: [Selection]
        let playhead: Int
    }

    private struct Edit {
        let before: EditState
        let after: EditState
    }

    private var recordingEdit = false
    @Published var timelineID: UUID?
    enum Selection: Hashable {
        case clip(UUID), source(UUID), layer(UUID)
    }

    struct ItemTransfer {
        let origin: UUID
        let items: [Selection]
    }

    @Published private(set) var selections: [Selection] = []
    private(set) var selection: Selection? {
        get { selections.last }
        set { selections = newValue.map { [$0] } ?? [] }
    }
    var hasTimelineSelection: Bool { selection != nil && sourceID == nil }
    var clipID: UUID? {
        if case let .clip(id) = selection { return id }
        return nil
    }
    var sourceID: UUID? {
        if case let .source(id) = selection { return id }
        return nil
    }
    var layerID: UUID? {
        if case let .layer(id) = selection { return id }
        return nil
    }
    @Published var projectURL: URL?
    @Published var error: String?
    @Published var previewError: String?
    @Published var loadingSources = false
    @Published var playhead = 0
    @Published private(set) var previewFrame = 0
    @Published var playing = false
    @Published var jobs: [ExportJob] = []
    struct ExportPlan: Identifiable {
        let id = UUID()
        let folder: URL
        let timelines: [Timeline]
        let prefixes: [String]
        var names: [String]
    }

    @Published var showingJobs = false
    @Published var exportPlan: ExportPlan?
    @Published var exporting = false

    let player = AVPlayer()
    private var observer: Any?
    private var previewEndObserver: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var saved = Project()
    private var lastImportedURL: URL?
    private let layerPreview = LayerPreviewGeometry()
    private var previewRefresh: Task<Void, Never>?
    private var committedPreviewID: UUID?
    private var projectGeneration = UUID()

    init() {
        saved = project
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.player.rate != 0 { self.updatePreviewPosition(at: time) }
                self.playing = self.player.rate != 0
            }
        }
    }

    var timelineIndex: Int { project.timelines.firstIndex { $0.id == timelineID } ?? 0 }
    var timeline: Timeline { project.timelines[timelineIndex] }
    var placements: [Placement] { layout(timeline.clips) }
    var clipFrames: Int { placements.last?.end ?? 0 }
    var totalFrames: Int { max(clipFrames, timeline.layers.map(\.end).max() ?? 0) }
    var previewFPS: Int { timeline.output.fps }
    var previewFrameCount: Int { totalFrames * (previewFPS / 30) }
    var selectedClip: Clip? { timeline.clips.first { $0.id == clipID } }
    var librarySources: [Source] { project.sources.filter { $0.hiddenFromLibrary != true } }
    var selectedSource: Source? { librarySources.first { $0.id == sourceID } }
    var selectedLayer: VisualLayer? { timeline.layers.first { $0.id == layerID } }
    var projectName: String? { project.name ?? projectURL?.deletingPathExtension().lastPathComponent }

    var canUndo: Bool { !undoEdits.isEmpty }
    var canRedo: Bool { !redoEdits.isEmpty }

    private var editState: EditState {
        EditState(project: project, timelineID: timeline.id, selections: selections, playhead: playhead)
    }

    private func edit(_ change: () -> Void) {
        guard !recordingEdit else { change(); return }
        let before = editState
        recordingEdit = true
        change()
        recordingEdit = false
        guard before.project != project else { return }
        undoEdits.append(Edit(before: before, after: editState))
        if undoEdits.count > 100 { undoEdits.removeFirst() }
        redoEdits.removeAll()
    }

    func undo() {
        guard let edit = undoEdits.popLast() else { return }
        restore(edit.before)
        redoEdits.append(edit)
    }

    func redo() {
        guard let edit = redoEdits.popLast() else { return }
        restore(edit.after)
        undoEdits.append(edit)
    }

    private var focusedTextUndoManager: UndoManager? {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager
    }

    func canPerformHistoryCommand(redo: Bool) -> Bool {
        if redo { return canRedo || focusedTextUndoManager?.canRedo == true }
        return canUndo || focusedTextUndoManager?.canUndo == true
    }

    func performHistoryCommand(redo: Bool) {
        if redo {
            if let manager = focusedTextUndoManager, manager.canRedo { manager.redo() }
            else { self.redo() }
        } else {
            if let manager = focusedTextUndoManager, manager.canUndo { manager.undo() }
            else { undo() }
        }
    }

    private func restore(_ state: EditState) {
        project = state.project
        timelineID = state.timelineID
        selections = state.selections
        seek(state.playhead)
    }

    func renameProject(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != projectName else { return }
        edit { project.name = String(name.prefix(100)) }
    }

    var dirty: Bool { saved != project }

    func updateTimeline(_ change: (inout Timeline) -> Void) {
        edit { change(&project.timelines[timelineIndex]) }
    }

    func updateOutputSizing(_ change: (inout OutputSettings) -> Void) {
        updateTimeline {
            change(&$0.output)
            $0.outputOrigin = .manual
        }
    }

    func selectTimeline(_ id: UUID) {
        guard timeline.id != id else { return }
        player.pause()
        playing = false
        timelineID = id
        selection = nil
        playhead = 0
        previewFrame = 0
    }

    func addTimeline() {
        addTimeline(with: nil)
    }

    func addTimeline(with source: Source?) {
        var index = 1
        while project.timelines.contains(where: { $0.name == L10n.format("タイムライン %@", String(describing: index)) }) { index += 1 }
        var new = Timeline(name: L10n.format("タイムライン %@", String(describing: index)))
        project.automaticOutput?.apply(to: &new)
        edit {
            project.timelines.append(new)
            selectTimeline(new.id)
            if let source { addClip(source) }
        }
    }

    var numbersTimelines: Bool { project.numberTimelines == true }

    func toggleTimelineNumbers() {
        edit { project.numberTimelines = numbersTimelines ? nil : true }
    }

    private func timelinePrefix(_ id: UUID) -> String? {
        guard numbersTimelines, let index = project.timelines.firstIndex(where: { $0.id == id }) else { return nil }
        return String(format: "%02d", index + 1)
    }

    func timelineDisplayName(_ timeline: Timeline) -> String {
        let name = timeline.name.isEmpty ? L10n.text("名称未設定") : timeline.name
        return timelinePrefix(timeline.id).map { "\($0) \(name)" } ?? name
    }

    func renameTimeline(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = project.timelines.firstIndex(where: { $0.id == id }) else { return }
        edit { project.timelines[index].name = name }
    }

    func renameTimelines(_ names: [UUID: String]) {
        edit {
            for index in project.timelines.indices {
                guard let draft = names[project.timelines[index].id] else { continue }
                let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { project.timelines[index].name = name }
            }
        }
    }

    func deleteTimeline(_ id: UUID) {
        guard project.timelines.count > 1,
              let index = project.timelines.firstIndex(where: { $0.id == id }) else { return }
        edit {
            if timeline.id == id {
                let replacement = project.timelines[index == 0 ? 1 : index - 1].id
                selectTimeline(replacement)
            }
            project.timelines.remove(at: index)
        }
    }

    func name(of clip: Clip) -> String {
        project.sources.first { $0.id == clip.sourceID }?.name ?? L10n.text("不明な素材")
    }

    func addClip(_ source: Source, at index: Int? = nil, to destination: UUID? = nil) {
        guard let target = project.timelines.firstIndex(where: { $0.id == (destination ?? timeline.id) }) else { return }
        let clip = Clip(sourceID: source.id, end: source.isImage ? min(150, source.frames) : source.frames)
        edit {
            let position = min(project.timelines[target].clips.count, max(0, index ?? project.timelines[target].clips.count))
            project.timelines[target].clips.insert(clip, at: position)
            if timelineIndex == target { selectClip(clip.id) }
        }
    }

    func moveClip(_ id: UUID, to insertion: Int) {
        _ = placeItems(itemsForTransfer(.clip(id)), in: timeline.id, insertion: insertion)
    }

    func duplicateClip(_ id: UUID) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        var copy = timeline.clips[index]
        copy.id = UUID()
        copy.continuationID = nil
        edit {
            updateTimeline { $0.clips.insert(copy, at: index + 1) }
            selectClip(copy.id)
        }
    }

    func drop(_ payload: String, at index: Int) -> Bool {
        let parts = payload.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return false }
        if parts[0] == "source", let source = project.sources.first(where: { $0.id == id }) {
            addClip(source, at: index)
            return true
        }
        return false
    }

    func itemsForTransfer(_ item: Selection) -> ItemTransfer {
        ItemTransfer(origin: timeline.id, items: selections.contains(item) ? selections : [item])
    }

    func beginItemDrag(_ item: Selection) -> ItemTransfer {
        if !selections.contains(item) { selection = item }
        return itemsForTransfer(item)
    }

    @discardableResult
    func placeItemsInNewTimeline(_ transfer: ItemTransfer, copy: Bool) -> Bool {
        guard let origin = project.timelines.first(where: { $0.id == transfer.origin }) else { return false }
        let items = Set(transfer.items)
        let count = origin.clips.filter { items.contains(.clip($0.id)) }.count
            + origin.layers.filter { items.contains(.layer($0.id)) }.count
        guard !items.isEmpty, count == items.count else { return false }
        // Creation and transfer form one undoable operation. Capture the transfer
        // before selecting the new timeline, including any Shift-selected items.
        var placed = false
        edit {
            addTimeline()
            updateTimeline {
                $0.output = origin.output
                $0.outputOrigin = origin.outputOrigin
            }
            placed = placeItems(transfer, in: timeline.id, copy: copy)
        }
        return placed
    }

    @discardableResult
    func placeItems(_ transfer: ItemTransfer, in destination: UUID,
                    insertion: Int? = nil, frame: Int? = nil, copy: Bool = false) -> Bool {
        guard let originIndex = project.timelines.firstIndex(where: { $0.id == transfer.origin }),
              let targetIndex = project.timelines.firstIndex(where: { $0.id == destination }) else { return false }
        var origin = project.timelines[originIndex]
        var target = project.timelines[targetIndex]
        let sameTimeline = originIndex == targetIndex
        let items = Set(transfer.items)
        var clips = origin.clips.filter { items.contains(.clip($0.id)) }
        var layers = origin.layers.filter { items.contains(.layer($0.id)) }
        guard !items.isEmpty, clips.count + layers.count == items.count else { return false }
        let oldClipStart = layout(origin.clips).first { items.contains(.clip($0.clip.id)) }?.start
        let oldLayerStart = layers.map(\.start).min()

        if !copy {
            let shift = sameTimeline ? 0 : Self.removedLeadingFrames(in: origin, items: items)
            origin.clips.removeAll { items.contains(.clip($0.id)) }
            if !sameTimeline {
                origin.layers = Self.shiftedLeadingLayers(
                    origin.layers.filter { !items.contains(.layer($0.id)) }, by: shift
                )
            } else {
                target = origin
            }
        }

        if copy || !sameTimeline {
            let usedClips = Set(target.clips.map(\.id))
            let usedLayers = Set(target.layers.map(\.id))
            var groups: [UUID: UUID] = [:]
            for index in clips.indices {
                if copy || usedClips.contains(clips[index].id) { clips[index].id = UUID() }
                if let group = clips[index].continuationID {
                    let mapped = groups[group] ?? UUID()
                    groups[group] = mapped
                    clips[index].continuationID = mapped
                }
            }
            for index in layers.indices where copy || usedLayers.contains(layers[index].id) {
                layers[index].id = UUID()
            }
        }

        if !clips.isEmpty {
            let original = project.timelines[targetIndex].clips
            let proposed = min(original.count, max(0, insertion ?? original.count))
            let removedBefore = sameTimeline && !copy
                ? original.prefix(proposed).filter { items.contains(.clip($0.id)) }.count : 0
            target.clips.insert(contentsOf: clips, at: proposed - removedBefore)
        }

        if let start = oldLayerStart {
            let newClipStart = clips.first.flatMap { first in layout(target.clips).first { $0.clip.id == first.id }?.start }
            let delta: Int
            if let oldClipStart, let newClipStart { delta = newClipStart - oldClipStart }
            else { delta = frame.map { $0 - start } ?? 0 }
            let lastEnd = layers.map(\.end).max() ?? start
            let shift = min(VisualLayer.maximumEnd - lastEnd, max(-start, delta))
            for index in layers.indices {
                layers[index].start += shift
                layers[index].end += shift
            }
            if sameTimeline && !copy {
                let updates = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
                target.layers = target.layers.map { updates[$0.id] ?? $0 }
            } else {
                target.layers += layers
            }
        }

        let placed = clips.map { Selection.clip($0.id) } + layers.map { Selection.layer($0.id) }
        edit {
            if !sameTimeline && !copy { project.timelines[originIndex] = origin }
            project.timelines[targetIndex] = target
            if timeline.id == destination {
                selections = sameTimeline && !copy ? transfer.items : placed
            } else if timeline.id == transfer.origin && !copy {
                selections.removeAll { items.contains($0) }
            }
        }
        return true
    }

    func selectClip(_ id: UUID, extending: Bool = false) { selectItem(.clip(id), extending: extending) }
    func selectSource(_ id: UUID) { selection = .source(id) }

    private func selectItem(_ item: Selection, extending: Bool) {
        if !extending || sourceID != nil {
            selection = item
        } else if selections.contains(item) {
            selections.removeAll { $0 == item }
        } else {
            selections.append(item)
        }
    }

    func removeSource(_ source: Source) {
        guard let index = project.sources.firstIndex(where: { $0.id == source.id }) else { return }
        edit {
            if project.timelines.contains(where: { timeline in
                timeline.clips.contains { $0.sourceID == source.id } || timeline.layers.contains { $0.sourceID == source.id }
            }) {
                project.sources[index].hiddenFromLibrary = true
            } else {
                project.sources.remove(at: index)
            }
            if sourceID == source.id { selection = nil }
        }
    }

    func deleteSelection() {
        if let source = selectedSource { removeSource(source) }
        else { removeItems(selections) }
    }

    func removeClip(_ id: UUID) {
        removeItems(itemsForTransfer(.clip(id)).items)
    }

    func removeLayer(_ id: UUID) {
        removeItems(itemsForTransfer(.layer(id)).items)
    }

    private func removeItems(_ items: [Selection]) {
        let items = Set(items)
        guard !items.isEmpty else { return }
        edit {
            updateTimeline { timeline in
                let shift = Self.removedLeadingFrames(in: timeline, items: items)
                timeline.clips.removeAll { items.contains(.clip($0.id)) }
                timeline.layers = Self.shiftedLeadingLayers(
                    timeline.layers.filter { !items.contains(.layer($0.id)) }, by: shift
                )
            }
            selections.removeAll { items.contains($0) }
        }
    }

    private static func removedLeadingFrames(in timeline: Timeline, items: Set<Selection>) -> Int {
        guard let first = timeline.clips.first, items.contains(.clip(first.id)) else { return 0 }
        let placements = layout(timeline.clips)
        return placements.first { !items.contains(.clip($0.clip.id)) }?.start ?? placements.last?.end ?? 0
    }

    private static func shiftedLeadingLayers(_ layers: [VisualLayer], by frames: Int) -> [VisualLayer] {
        guard frames > 0 else { return layers }
        return layers.map { layer in
            var moved = layer
            let shift = min(layer.start, frames)
            moved.start -= shift
            moved.end -= shift
            return moved
        }
    }

    func addLayer(_ kind: LayerKind, source: Source? = nil) {
        guard kind != .image || source?.isImage == true else { return }
        let start = min(playhead, VisualLayer.maximumEnd - 90)
        let region: CanvasRegion
        switch kind {
        case .text: region = CanvasRegion(x: 0.1, y: 0.69, width: 0.8, height: 0.23)
        case .image: region = CanvasRegion(x: 0.23, y: 0.23, width: 0.54, height: 0.54)
        case .rectangle: region = CanvasRegion(x: 0.3, y: 0.35, width: 0.4, height: 0.3)
        case .blur, .mosaic: region = CanvasRegion(x: 0.32, y: 0.32, width: 0.36, height: 0.36)
        }
        var layer = VisualLayer(kind: kind, start: start, end: start + 90, region: region, sourceID: source?.id)
        if kind == .text {
            let canvas = timeline.output.size
            layer.outlinePixels = layer.strokePixels(in: canvas)
            layer.fontSizePoints = layer.textPoints(in: canvas)
        }
        edit {
            updateTimeline { $0.layers.append(layer) }
            selectLayer(layer.id)
        }
    }

    func duplicateLayer() {
        if let layerID { duplicateLayer(layerID) }
    }

    func duplicateLayer(_ id: UUID) {
        guard let index = timeline.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = timeline.layers[index]
        copy.id = UUID()
        edit {
            updateTimeline { $0.layers.insert(copy, at: index + 1) }
            selectLayer(copy.id)
        }
    }

    func selectLayer(_ id: UUID, extending: Bool = false) {
        guard let layer = timeline.layers.first(where: { $0.id == id }) else { return }
        selectItem(.layer(id), extending: extending)
        guard !extending else { return }
        let displayedPosition = min(playhead, max(0, totalFrames - 1))
        if !(layer.start..<layer.end).contains(displayedPosition) { seek(layer.start) }
    }

    func updateLayer(_ id: UUID, _ change: (inout VisualLayer) -> Void) {
        guard let index = timeline.layers.firstIndex(where: { $0.id == id }) else { return }
        updateTimeline {
            var layers = $0.layers
            change(&layers[index])
            layers[index].region = layers[index].region.contained()
            $0.layers = layers
        }
    }

    func trimLayer(_ id: UUID, start: Int? = nil, end: Int? = nil) {
        updateLayer(id) {
            let previousStart = $0.start
            let previousEnd = $0.end
            if let start { $0.start = min($0.end - 1, max(0, start)) }
            if let end { $0.end = min(VisualLayer.maximumEnd, max($0.start + 1, end)) }
            if $0.start != previousStart || $0.end != previousEnd { $0.animationSpan = nil }
        }
    }

    func canReorderLayer(by step: Int, id: UUID? = nil) -> Bool {
        let layers = timeline.layers
        guard let id = id ?? layerID, let index = layers.firstIndex(where: { $0.id == id }) else { return false }
        return layers.indices.contains(index + step)
    }

    func reorderLayer(by step: Int, id: UUID? = nil) {
        let layers = timeline.layers
        guard let id = id ?? layerID, let index = layers.firstIndex(where: { $0.id == id }),
              layers.indices.contains(index + step) else { return }
        updateTimeline { $0.layers.swapAt(index, index + step) }
    }

    func updateClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        updateTimeline { change(&$0.clips[index]) }
    }

    func trim(_ id: UUID, start: Int? = nil, end: Int? = nil) {
        guard let clip = timeline.clips.first(where: { $0.id == id }),
              let source = project.sources.first(where: { $0.id == clip.sourceID }) else { return }
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        updateTimeline {
            if let start {
                $0.clips[index].start = min(max(0, start), clip.end - 1)
                $0.clips[index].sourceIn = nil
            }
            if let end {
                $0.clips[index].end = min(max($0.clips[index].start + 1, end), source.frames)
                $0.clips[index].sourceOut = nil
            }
            $0.clips[index].timelineFrames = nil
            if index == 0 {
                let removed = max(0, Int((($0.clips[index].sourceStart - clip.sourceStart) / clip.sourceFramesPerTimelineFrame).rounded()))
                $0.layers = Self.shiftedLeadingLayers($0.layers, by: removed)
            }
        }
    }

    func trimTimeline(_ id: UUID, leading: Bool, delta: Int) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }),
              let source = project.sources.first(where: { $0.id == timeline.clips[index].sourceID }) else { return }
        let clip = timeline.clips[index]
        let rate = clip.sourceFramesPerTimelineFrame
        let limits = leading
            ? Int(ceil(-clip.sourceStart / rate))...(clip.length - 1)
            : (1 - clip.length)...Int(floor((Double(source.frames) - clip.sourceEnd) / rate))
        let delta = min(limits.upperBound, max(limits.lowerBound, delta))
        guard delta != 0 else { return }
        updateTimeline {
            let start = leading ? max(0, clip.sourceStart + Double(delta) * rate) : clip.sourceStart
            let end = leading ? clip.sourceEnd : min(Double(source.frames), clip.sourceEnd + Double(delta) * rate)
            $0.clips[index].setSourceRange(start: start, end: end, duration: clip.length + (leading ? -delta : delta))
            if index == 0 && leading { $0.layers = Self.shiftedLeadingLayers($0.layers, by: delta) }
        }
    }

    func setSpeed(_ id: UUID, percent: Double) {
        guard percent.isFinite else { return }
        let speed = min(Clip.speedRange.upperBound, max(Clip.speedRange.lowerBound, percent / 100))
        guard timeline.clips.first(where: { $0.id == id })?.playbackRate != speed else { return }
        updateClip(id) {
            $0.speed = speed == 1 ? nil : speed
            $0.timelineFrames = nil
            $0.continuationID = nil
        }
    }

    var canSplit: Bool {
        guard playhead > 0 && playhead < totalFrames else { return false }
        return placements.contains { $0.start < playhead && playhead < $0.end }
            || timeline.layers.contains { $0.start < playhead && playhead < $0.end }
    }

    func split() {
        guard canSplit else { return }
        let cut = playhead
        let clipCuts = Dictionary(uniqueKeysWithValues: placements
            .filter { $0.start < cut && cut < $0.end }
            .map { ($0.clip.id, cut - $0.start) })
        let previousSelection = selections
        var replacements: [Selection: Selection] = [:]
        var fallback: Selection?

        edit {
            updateTimeline { timeline in
                timeline.clips = timeline.clips.flatMap { clip in
                    guard let length = clipCuts[clip.id] else { return [clip] }
                    let point = clip.sourceStart + Double(length) * clip.sourceFramesPerTimelineFrame
                    let group = clip.continuationID ?? UUID()
                    var left = clip
                    var right = clip
                    left.setSourceRange(start: clip.sourceStart, end: point, duration: length)
                    left.fadeOut = false
                    left.transition = .cut
                    left.continuationID = group
                    right.id = UUID()
                    right.setSourceRange(start: point, end: clip.sourceEnd, duration: clip.length - length)
                    right.fadeIn = false
                    right.continuationID = group
                    replacements[.clip(clip.id)] = .clip(right.id)
                    if fallback == nil { fallback = .clip(right.id) }
                    return [left, right]
                }
                timeline.layers = timeline.layers.flatMap { layer in
                    guard layer.start < cut && cut < layer.end else { return [layer] }
                    var left = layer
                    var right = layer
                    left.end = cut
                    right.id = UUID()
                    right.start = cut
                    if (layer.entrance ?? .cut) != .cut || (layer.exit ?? .cut) != .cut {
                        left.animationSpan = .init(offset: layer.animationStart - left.start, length: layer.animationLength)
                        right.animationSpan = .init(offset: layer.animationStart - right.start, length: layer.animationLength)
                    }
                    replacements[.layer(layer.id)] = .layer(right.id)
                    if fallback == nil { fallback = .layer(right.id) }
                    return [left, right]
                }
            }
            selections = previousSelection.count > 1
                ? previousSelection.map { replacements[$0] ?? $0 }
                : (previousSelection.first.flatMap { replacements[$0] } ?? fallback).map { [$0] } ?? []
        }
    }

    func seek(_ frame: Int) {
        player.pause()
        playing = false
        playhead = min(totalFrames, max(0, frame))
        // The end marker is a boundary. The final displayed sample is one output frame earlier.
        previewFrame = min(playhead * (previewFPS / 30), max(0, previewFrameCount - 1))
        let time = CMTime(value: Int64(previewFrame), timescale: Int32(previewFPS))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if player.rate == 0 {
            if playhead >= totalFrames { seek(0) }
            player.play()
        } else {
            player.pause()
            updatePreviewPosition(at: player.currentTime())
        }
        playing = player.rate != 0
    }

    private func updatePreviewPosition(at time: CMTime) {
        guard time.seconds.isFinite else { return }
        let fps = previewFPS
        let total = totalFrames
        let frame = Int(time.convertScale(Int32(fps), method: .roundTowardZero).value)
        let shown = min(max(0, frame), max(0, total * (fps / 30) - 1))
        if previewFrame != shown { previewFrame = shown }
        let position = min(total, max(0, Int(time.convertScale(30, method: .roundTowardZero).value)))
        if playhead != position { playhead = position }
    }

    private func replacePreviewItem(with item: AVPlayerItem?) {
        previewEndObserver = item.map { item in
            NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] _ in
                    MainActor.assumeIsolated {
                        guard let self, let item, self.player.currentItem === item,
                              self.player.currentTime() >= frameTime(max(0, self.totalFrames - 1)) else { return }
                        self.seek(self.totalFrames)
                    }
                }
        }
        player.replaceCurrentItem(with: item)
    }

    func previewLayerRegion(_ id: UUID, region: CanvasRegion) {
        guard selectedLayer?.id == id, !playing else { return }
        committedPreviewID = nil
        layerPreview.set(id: id, region: region)
        refreshLayerPreview()
    }

    func commitLayerRegion(_ id: UUID, region: CanvasRegion) {
        guard let layer = selectedLayer, layer.id == id, region != layer.region else {
            cancelLayerPreview(id)
            return
        }
        layerPreview.set(id: id, region: region)
        committedPreviewID = id
        refreshLayerPreview()
        updateLayer(id) { $0.region = region }
    }

    func cancelLayerPreview(_ id: UUID) {
        guard committedPreviewID != id, layerPreview.clear(id: id) else { return }
        refreshLayerPreview()
    }

    private func refreshLayerPreview() {
        guard previewRefresh == nil else { return }
        previewRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, !Task.isCancelled else { return }
            self.previewRefresh = nil
            guard let item = self.player.currentItem,
                  let composition = item.videoComposition?.mutableCopy() as? AVVideoComposition else { return }
            // A fresh video composition makes a paused AVPlayer redraw its current frame.
            item.videoComposition = composition
        }
    }

    func rebuildPreview() async {
        let sequence = timeline
        let sources = project.sources
        previewError = nil
        if !sequence.hasContent {
            clearCommittedLayerPreview()
            replacePreviewItem(with: nil)
            playhead = 0
            previewFrame = 0
            playing = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(100))
            let edit = try await compose(sequence, sources: sources, layerPreview: layerPreview)
            try Task.checkCancellation()
            clearCommittedLayerPreview()
            replacePreviewItem(with: edit.playerItem())
            seek(playhead)
        } catch {
            guard !Task.isCancelled else { return }
            clearCommittedLayerPreview()
            replacePreviewItem(with: nil)
            playing = false
            previewError = error.localizedDescription
        }
    }

    private func clearCommittedLayerPreview() {
        guard let id = committedPreviewID else { return }
        _ = layerPreview.clear(id: id)
        committedPreviewID = nil
    }

    private func mediaPanel(multiple: Bool, types: [UTType]) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.title = multiple ? L10n.text("素材を読み込む") : L10n.text("元ファイルを再指定")
        panel.prompt = multiple ? L10n.text("読み込む") : L10n.text("選択")
        return panel
    }

    func chooseSources() {
        let panel = mediaPanel(multiple: true, types: [.mpeg4Movie, .quickTimeMovie, .image])
        if panel.runModal() == .OK { importSources(panel.urls) }
    }

    func importSources(_ urls: [URL]) {
        guard !loadingSources else { return }
        loadingSources = true
        Task {
            defer { loadingSources = false }
            var errors: [String] = []
            for url in urls {
                do {
                    let source = try await registerSource(url)
                    selectSource(source.id)
                } catch {
                    errors.append("\(url.lastPathComponent) — \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { error = errors.joined(separator: "\n") }
        }
    }

    private func registerSource(_ url: URL) async throws -> Source {
        let generation = projectGeneration
        let url = url.standardizedFileURL
        if let index = project.sources.firstIndex(where: { $0.path == url.path }) {
            edit {
                project.sources[index].hiddenFromLibrary = nil
                if project.automaticOutput == nil, project.sources.first(where: { !$0.isImage })?.id == project.sources[index].id,
                   let info = project.sources[index].videoInfo {
                    applyOutputDefaults(info, sourceIndex: index)
                }
            }
            lastImportedURL = url
            let existing = project.sources[index]
            await initializeOutputDefaults()
            return existing
        }
        let source = try await inspectSource(url)
        guard generation == projectGeneration else { throw CancellationError() }
        edit {
            project.sources.append(source)
            if project.automaticOutput == nil, project.sources.first(where: { !$0.isImage })?.id == source.id,
               let info = source.videoInfo {
                applyOutputDefaults(info, sourceIndex: project.sources.count - 1)
            }
        }
        lastImportedURL = url
        await initializeOutputDefaults()
        return source
    }

    private func initializeOutputDefaults() async {
        guard project.automaticOutput == nil, let source = project.sources.first(where: { !$0.isImage }) else { return }
        let generation = projectGeneration
        let info: SourceVideoInfo?
        if let saved = source.videoInfo { info = saved }
        else { info = try? await inspectSource(source.url).videoInfo }
        guard generation == projectGeneration, project.automaticOutput == nil, let info, info.isValid,
              let index = project.sources.firstIndex(where: { $0.id == source.id }) else { return }
        edit { applyOutputDefaults(info, sourceIndex: index) }
    }

    private func applyOutputDefaults(_ info: SourceVideoInfo, sourceIndex: Int) {
        project.sources[sourceIndex].videoInfo = info
        let defaults = info.closestOutput
        project.automaticOutput = defaults
        for index in project.timelines.indices where project.timelines[index].outputOrigin == .awaitingSource {
            defaults.apply(to: &project.timelines[index])
        }
    }

    func chooseLayerImage() {
        guard !loadingSources else { return }
        let panel = mediaPanel(multiple: false, types: [.image])
        panel.title = L10n.text("画像レイヤーを追加")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let timelineID = timeline.id
        loadingSources = true
        Task {
            defer { loadingSources = false }
            do {
                let source = try await registerSource(url)
                if timeline.id == timelineID { addLayer(.image, source: source) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func relink(_ source: Source) {
        guard !loadingSources else { return }
        let panel = mediaPanel(multiple: false, types: source.isImage ? [.image] : [.mpeg4Movie, .quickTimeMovie])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadingSources = true
        Task {
            defer { loadingSources = false }
            do {
                var replacement = try await inspectSource(url)
                guard replacement.isImage == source.isImage else {
                    throw MovieError(L10n.text("元の素材と同じ種類のファイルを選択してください。"))
                }
                let usedEnd = project.timelines.flatMap(\.clips).filter { $0.sourceID == source.id }.map(\.end).max() ?? 0
                guard replacement.frames >= usedEnd else {
                    throw MovieError(L10n.text("選んだファイルは、タイムラインで使用中の区間より短い動画です。"))
                }
                if let index = project.sources.firstIndex(where: { $0.id == source.id }) {
                    replacement.id = source.id
                    replacement.hiddenFromLibrary = project.sources[index].hiddenFromLibrary
                    edit { project.sources[index] = replacement }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var projectType: UTType { UTType(exportedAs: "local.cygnus-movies.project", conformingTo: .data) }

    func associateProjectFiles() {
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: projectType)
                let alert = NSAlert()
                alert.messageText = L10n.text("プロジェクトファイルを関連付けました")
                alert.informativeText = L10n.text(".cygnusmovies をダブルクリックすると、このアプリで開きます。")
                alert.addButton(withTitle: L10n.text("閉じる"))
                alert.runModal()
            } catch {
                self.error = L10n.format("プロジェクトファイルを関連付けできませんでした。\n%@", String(describing: error.localizedDescription))
            }
        }
    }

    @discardableResult
    func save(asNew: Bool = false) -> Bool {
        var target = asNew ? nil : projectURL
        if target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [projectType]
            panel.title = L10n.text("プロジェクトを保存")
            panel.prompt = L10n.text("保存")
            panel.nameFieldLabel = L10n.text("ファイル名:")
            let name = (projectName ?? L10n.text("名称未設定")).components(separatedBy: Self.invalidFilenameCharacters)
                .joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            panel.nameFieldStringValue = (name.isEmpty ? L10n.text("名称未設定") : name) + ".cygnusmovies"
            guard panel.runModal() == .OK else { return false }
            target = panel.url
        }
        guard let target else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: target, options: .atomic)
            projectURL = target
            saved = project
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func mayDiscardChanges() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text("プロジェクトの変更を保存しますか？")
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("キャンセル"))
        alert.addButton(withTitle: L10n.text("保存しない")).hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newProject() {
        guard !loadingSources, mayDiscardChanges() else { return }
        replaceProject(Project(), url: nil)
    }

    func openProject() {
        guard !loadingSources else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.title = L10n.text("プロジェクトを開く")
        panel.prompt = L10n.text("開く")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    @discardableResult
    func openProject(at url: URL) -> Bool {
        guard !loadingSources, mayDiscardChanges() else { return false }
        do {
            let document = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            try document.validate()
            replaceProject(document, url: url)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func replaceProject(_ document: Project, url: URL?) {
        projectGeneration = UUID()
        player.replaceCurrentItem(with: nil)
        layerPreview.reset()
        committedPreviewID = nil
        previewRefresh?.cancel()
        previewRefresh = nil
        lastImportedURL = nil
        undoEdits.removeAll()
        redoEdits.removeAll()
        project = document
        saved = document
        projectURL = url
        timelineID = nil
        selection = nil
        playhead = 0
        previewFrame = 0
        playing = false
        Task { await initializeOutputDefaults() }
    }

    var initialExportDirectory: URL? {
        let location = projectURL ?? lastImportedURL ?? project.sources.last?.url
        guard let folder = location?.deletingLastPathComponent() else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? folder : nil
    }

    func suggestedExportName(for timeline: Timeline, timestamp: String) -> String {
        let cleaned = [projectName, timeline.name].compactMap { $0 }.joined(separator: "-")
            .components(separatedBy: Self.invalidFilenameCharacters).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        var base = cleaned.isEmpty ? L10n.text("動画") : cleaned
        while base.utf8.count > 180 { base.removeLast() }
        return "\(base)-\(timestamp)"
    }

    func startExport(all: Bool, for id: UUID? = nil) {
        guard !exporting else { showingJobs = true; return }
        let targets = all ? project.timelines : project.timelines.filter { $0.id == (id ?? timeline.id) }
        let timelines = targets.filter(\.hasContent)
        guard !timelines.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = L10n.text("書き出し先を選択")
        panel.prompt = L10n.text("フォルダを選択")
        panel.directoryURL = initialExportDirectory
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        var reserved = Set<String>()
        let prefixes = timelines.map { timelinePrefix($0.id).map { "\($0)-" } ?? "" }
        let names = zip(timelines, prefixes).map { timeline, prefix in
            let name = suggestedExportName(for: timeline, timestamp: timestamp)
            let fileExtension = timeline.output.container.rawValue
            var unique = name
            var suffix = 2
            while reserved.contains(Self.filenameKey("\(prefix)\(unique).\(fileExtension)")) ||
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(prefix)\(unique).\(fileExtension)").path) {
                unique = "\(name)-\(suffix)"
                suffix += 1
            }
            reserved.insert(Self.filenameKey("\(prefix)\(unique).\(fileExtension)"))
            return unique
        }
        exportPlan = ExportPlan(folder: folder, timelines: timelines, prefixes: prefixes, names: names)
    }

    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)

    private static func filenameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    func confirmExport(_ plan: ExportPlan) throws {
        guard !exporting else { return }
        var reserved = Set<String>()
        let plannedJobs = try plan.timelines.indices.map { index in
            let timeline = plan.timelines[index]
            let input = plan.names[index]
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = ".\(timeline.output.container.rawValue)"
            let filename = plan.prefixes[index] + (name.lowercased().hasSuffix(ext) ? name : name + ext)
            guard !name.isEmpty, !name.hasPrefix("."), name.rangeOfCharacter(from: Self.invalidFilenameCharacters) == nil,
                  filename.utf8.count <= 255 else {
                throw MovieError(L10n.format("「%@」のファイル名を確認してください。", String(describing: timeline.name)))
            }
            let destination = plan.folder.appendingPathComponent(filename)
            guard reserved.insert(Self.filenameKey(filename)).inserted,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw MovieError(L10n.format("「%@」が重複しています。別の名前を指定してください。", String(describing: filename)))
            }
            return ExportJob(timeline: timeline, destination: destination)
        }
        jobs = plannedJobs
        exportPlan = nil

        let queue = jobs
        let sources = project.sources
        let useHardware = EncodingPreferences.useHardware
        exporting = true
        exportTask = Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for lane in 0..<min(2, queue.count) {
                    group.addTask { [weak self] in
                        for index in stride(from: lane, to: queue.count, by: 2) {
                            let job = queue[index]
                            do {
                                try Task.checkCancellation()
                                await self?.updateJob(job.id, status: .exporting)
                                try await exportMovie(job.timeline, sources: sources, to: job.destination,
                                                      useHardware: useHardware, encoderSelected: { [weak self] mode in
                                    await self?.recordEncoder(job.id, mode: mode)
                                }) { [weak self] value in
                                    await self?.updateJob(job.id, progress: value)
                                }
                                await self?.updateJob(job.id, status: .complete, progress: 1)
                            } catch {
                                let status = Task.isCancelled ? ExportStatus.canceled : .failed(error.localizedDescription)
                                await self?.updateJob(job.id, status: status)
                            }
                        }
                    }
                }
            }
            await self?.finishExports()
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func recordEncoder(_ id: UUID, mode: EncodingMode) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].encoder = mode
    }

    private func finishExports() {
        exporting = false
        exportTask = nil
    }

    private func updateJob(_ id: UUID, status: ExportStatus? = nil, progress: Double? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let status { jobs[index].status = status }
        if let progress { jobs[index].progress = progress }
    }
}
