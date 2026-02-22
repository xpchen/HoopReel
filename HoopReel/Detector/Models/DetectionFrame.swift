import Foundation
import CoreGraphics

// MARK: - BBox

/// Normalized bounding box (center-x, center-y, width, height) in [0, 1].
struct BBox {
    let x: Float          // center-x, normalized
    let y: Float          // center-y, normalized (0 = top)
    let w: Float          // width, normalized
    let h: Float          // height, normalized
    let confidence: Float

    /// Returns the bottom-center y of this box (useful for tracking ball descent).
    var bottomY: Float { y + h * 0.5 }

    /// Intersection-over-Union with another BBox.
    func iou(with other: BBox) -> Float {
        let x1 = max(x - w * 0.5, other.x - other.w * 0.5)
        let y1 = max(y - h * 0.5, other.y - other.h * 0.5)
        let x2 = min(x + w * 0.5, other.x + other.w * 0.5)
        let y2 = min(y + h * 0.5, other.y + other.h * 0.5)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = w * h + other.w * other.h - intersection
        return union > 0 ? intersection / union : 0
    }
}

// MARK: - DetectionFrame

/// All ML detections for a single sampled video frame.
struct DetectionFrame {
    let frameIndex: Int
    let timestamp:  Double    // seconds from video start
    let ball:       BBox?     // nil if ball not detected this frame
    let hoop:       BBox?     // nil if hoop not detected (use calibrated fallback)
    let players:    [BBox]    // optional: player bboxes for false-positive filtering
}
