import AppKit
import SwiftUI

struct PreferenceProbe {
    @AppStorage var waveform: Bool
    @AppStorage var snapping: Bool
    @AppStorage var zoom: Double
    @AppStorage var fittedFrames: Int
    init(store: UserDefaults) {
        _waveform = AppStorage(wrappedValue: false, TimelinePreferences.waveform, store: store)
        _snapping = AppStorage(wrappedValue: true, TimelinePreferences.snapping, store: store)
        _zoom = AppStorage(wrappedValue: 0.56, TimelinePreferences.zoom, store: store)
        _fittedFrames = AppStorage(wrappedValue: 0, TimelinePreferences.fittedFrames, store: store)
    }
}

@main struct TimelineTransferCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = Source(path: folder.appendingPathComponent("fixture.png").path, frames: 900,
                            stillImage: true)
        let first = Clip(sourceID: source.id, end: 120)
        let second = Clip(sourceID: source.id, end: 240)
        let layer = VisualLayer(kind: .text, start: 150, end: 210,
                                region: CanvasRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.3))
        var origin = Timeline(name: "Original", clips: [first, second])
        origin.layers = [layer]
        origin.output.aspectRatio = .portrait
        origin.output.frameRate = .fps60
        origin.outputOrigin = .manual
        origin.showWaveform = true // Older documents still decode safely.
        let document = Project(sources: [source], timelines: [origin])
        let file = folder.appendingPathComponent("input.cygnusmovies")
        try JSONEncoder().encode(document).write(to: file)
        for copy in [false, true] {
            let editor = Editor()
            precondition(editor.openProject(at: file))
            let before = editor.project
            editor.selectClip(second.id)
            editor.selectLayer(layer.id, extending: true)
            let transfer = editor.itemsForTransfer(.clip(second.id))
            precondition(editor.placeItemsInNewTimeline(transfer, copy: copy))
            precondition(editor.project.timelines.count == 2)
            let target = editor.timeline
            precondition(target.id != origin.id && target.clips.count == 1 && target.layers.count == 1)
            precondition(target.output == origin.output && target.outputOrigin == origin.outputOrigin)
            precondition(target.layers[0].start == 30 && target.layers[0].end == 90)
            precondition(target.clips[0].sourceID == source.id)
            precondition(editor.project.sources.count == 1)
            if copy {
                precondition(editor.project.timelines[0] == origin)
                precondition(target.clips[0].id != second.id && target.layers[0].id != layer.id)
            } else {
                precondition(editor.project.timelines[0].clips == [first])
                precondition(editor.project.timelines[0].layers.isEmpty)
                precondition(target.clips[0].id == second.id && target.layers[0].id == layer.id)
            }
            try editor.project.validate()
            let after = editor.project
            editor.undo()
            precondition(editor.project == before && editor.timeline.id == origin.id)
            editor.redo()
            precondition(editor.project == after && editor.timeline.id == target.id)
            print("PASS new timeline", copy ? "copy" : "move", "with multi-selection, output settings, layer timing, one-step undo/redo")
        }
        let editor = Editor()
        precondition(editor.openProject(at: file))
        let invalid = Editor.ItemTransfer(origin: origin.id, items: [.clip(UUID())])
        precondition(!editor.placeItemsInNewTimeline(invalid, copy: false))
        precondition(editor.project.timelines.count == 1 && !editor.canUndo)
        precondition(editor.placeItemsInNewTimeline(editor.itemsForTransfer(.clip(first.id)), copy: true))
        precondition(editor.timeline.clips.count == 1 && editor.timeline.layers.isEmpty)
        print("PASS single clip and invalid selection without creating an empty timeline")

        let suite = "local.cygnus-movies.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = PreferenceProbe(store: defaults)
        a.waveform = true; a.snapping = false; a.zoom = 0.21; a.fittedFrames = 108_000
        let b = PreferenceProbe(store: defaults)
        precondition(b.waveform && !b.snapping && b.zoom == 0.21 && b.fittedFrames == 108_000)
        let scale = TimelineScale(width: 1200)
        let sharedScale = scale.pointsPerSecond(zoom: b.zoom, fittedFrames: b.fittedFrames)
        precondition(sharedScale == scale.pointsPerSecond(zoom: a.zoom, fittedFrames: a.fittedFrames))
        a.fittedFrames = 0; a.zoom = 0.4; a.waveform = false
        let reopened = PreferenceProbe(store: UserDefaults(suiteName: suite)!)
        precondition(!reopened.waveform && !reopened.snapping && reopened.zoom == 0.4 && reopened.fittedFrames == 0)
        print("PASS shared preferences persist across consumers and reopening, including the fit reference scale")
    }
}
