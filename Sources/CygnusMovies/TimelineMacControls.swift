import AppKit
import SwiftUI

struct TimelineWheel: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {}

    final class WheelView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }

            if let scroll = enclosingScrollView {
                scroll.hasHorizontalScroller = true
                scroll.autohidesScrollers = false
                scroll.scrollerStyle = .legacy
                scroll.horizontalScroller?.controlSize = .regular
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !event.modifierFlags.contains(.option),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      let scroll = self.enclosingScrollView else { return event }
                let clip = scroll.contentView
                let pointer = clip.convert(event.locationInWindow, from: nil)
                guard clip.bounds.contains(pointer) else { return event }

                let rect = clip.documentRect
                let minimum = rect.minX
                let maximum = rect.maxX - clip.bounds.width
                guard maximum > minimum else { return event }
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                var origin = clip.bounds.origin
                origin.x = min(maximum, max(minimum, origin.x - event.scrollingDeltaY * unit))
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct TrimCursor: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.enabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var enabled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            if enabled { addCursorRect(bounds, cursor: .resizeLeftRight) }
        }
    }
}
