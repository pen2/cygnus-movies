import CoreTransferable
import Foundation

import UniformTypeIdentifiers

struct TimelineDragAvatar {
    let location: CGPoint
    let title: String
    let symbol: String
    let source: Source?
    let frame: Int
    let count: Int
    let copying: Bool
}

struct TimelineDrag: Transferable {
    let payload: String

    static let contentType = UTType(exportedAs: "local.cygnus-movies.timeline-drag", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: contentType) { drag in Data(drag.payload.utf8) }
    }

}

struct TimelineScale {
    static let inset = 14.0
    static let editorSpace = "timelineEditor"
    private static let manualMaximum = 900.0
    let usableWidth: Double

    init(width: Double) {
        usableWidth = max(1, width - 2 * Self.inset - 24)
    }

    private var minimum: Double { usableWidth / 1800 }

    func pointsPerSecond(zoom: Double, fittedFrames: Int?) -> Double {
        if let fittedFrames, fittedFrames > 0 { return usableWidth * 30 / Double(fittedFrames) }
        return minimum * pow(max(1.01, Self.manualMaximum / minimum), zoom)
    }

    func zoomToFit(frames: Int) -> Double {
        guard frames > 0 else { return 0 }
        let scale = pointsPerSecond(zoom: 0, fittedFrames: frames)
        let fraction = log(scale / minimum) / log(max(1.01, Self.manualMaximum / minimum))
        return min(1, max(0, fraction))
    }
}

struct TimelineSnap {
    struct Adjustment: Equatable {
        let delta: Int
        let guide: Int
        let snapped: Bool
    }

    let pointsPerFrame: Double
    let targets: [Int]
    private let tolerance = 8.0

    func adjust(translation: Double, edges: [Int], limits: ClosedRange<Int>) -> Adjustment {
        let shift = translation / pointsPerFrame
        let free = min(limits.upperBound, max(limits.lowerBound, Int(shift.rounded())))
        var nearest = Adjustment(delta: free, guide: edges[0] + free, snapped: false)
        var distance = tolerance
        for edge in edges {
            for target in targets {
                let delta = target - edge
                let pixels = abs(Double(delta) * pointsPerFrame - translation)
                if limits.contains(delta), pixels <= distance, !nearest.snapped || pixels < distance {
                    nearest = Adjustment(delta: delta, guide: target, snapped: true)
                    distance = pixels
                }
            }
        }
        return nearest
    }
}
