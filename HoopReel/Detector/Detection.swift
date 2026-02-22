import Foundation
import CoreGraphics

// MARK: - Detection

/// A single object detection from one video frame.
///
/// `rectNormalized` uses **Vision coordinates** (origin at bottom-left, values in [0, 1]).
/// When rendering to screen (top-left origin) the y axis must be flipped:
///     flippedY = 1 - rect.origin.y - rect.size.height
struct Detection: Identifiable, Sendable {
    let id = UUID()
    let label: String            // e.g. "Basketball", "Basketball Hoop"
    let confidence: Double       // 0 – 1
    let rectNormalized: CGRect   // Vision coords: origin bottom-left, [0, 1]
    let timeSeconds: Double      // presentation time in the source video

    /// Returns `rectNormalized` converted to top-left origin (SwiftUI / UIKit coords).
    var rectTopLeft: CGRect {
        CGRect(
            x:      rectNormalized.origin.x,
            y:      1 - rectNormalized.origin.y - rectNormalized.size.height,
            width:  rectNormalized.size.width,
            height: rectNormalized.size.height
        )
    }
}
