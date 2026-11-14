import AppKit
import AVFoundation
import SwiftUI

func renderedPreviewFrame(_ timeline: Timeline, sources: [Source], frame: Int) async throws -> CGImage {
    let edit = try await compose(timeline, sources: sources)
    let generator = AVAssetImageGenerator(asset: edit.asset)
    generator.videoComposition = edit.video
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let fps = timeline.output.fps
    let last = max(0, edit.frames * (fps / 30) - 1)
    return try await generator.image(at: CMTime(value: Int64(min(last, max(0, frame))), timescale: Int32(fps))).image
}

struct FrameShareButton: NSViewRepresentable {
    @ObservedObject var editor: Editor

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L10n.text("画像を共有"))!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = NSColor(red: 0.43, green: 0.85, blue: 0.81, alpha: 1)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.editor = editor
        button.isEnabled = editor.canCaptureFrame && !context.coordinator.busy
        button.toolTip = L10n.text("画像を共有")
    }
    final class Coordinator: NSObject {
        var editor: Editor
        var busy = false
        init(editor: Editor) { self.editor = editor }
        @MainActor @objc func share(_ sender: NSButton) {
            guard !busy else { return }
            busy = true
            sender.isEnabled = false
            let timeline = editor.timeline, sources = editor.project.sources, frame = editor.previewFrame
            Task { @MainActor in
                defer { busy = false; sender.isEnabled = editor.canCaptureFrame }
                do {
                    let image = try await renderedPreviewFrame(timeline, sources: sources, frame: frame)
                    let picker = NSSharingServicePicker(items: [NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
                    picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
                } catch { editor.error = error.localizedDescription }
            }
        }
    }
}

struct WindowTitleBridge: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title; view.window?.title = title }
    final class TitleView: NSView {
        var title = "cygnus movies"
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.title = title }
    }
}
