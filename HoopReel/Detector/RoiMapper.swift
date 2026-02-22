import CoreGraphics

// MARK: - RoiMapper

/// Pure-function utilities for ROI expansion, clamping, and coordinate mapping.
///
/// All rects are in **Vision coordinate space** (bottom-left origin, normalised 0–1)
/// unless explicitly labelled "screen" (SwiftUI top-left origin).
enum RoiMapper {

    // MARK: - Geometry

    /// Expands `rect` around its centre by `factor` (e.g. 2.2 → 2.2× larger in both axes).
    nonisolated static func expand(_ rect: CGRect, by factor: Double) -> CGRect {
        let cx = rect.midX
        let cy = rect.midY
        let w  = rect.width  * factor
        let h  = rect.height * factor
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Clamps all edges of `rect` to [0, 1] × [0, 1].
    nonisolated static func clamp(_ rect: CGRect) -> CGRect {
        let x  = max(0, min(1, rect.minX))
        let y  = max(0, min(1, rect.minY))
        let x2 = max(0, min(1, rect.maxX))
        let y2 = max(0, min(1, rect.maxY))
        return CGRect(x: x, y: y, width: x2 - x, height: y2 - y)
    }

    /// Expands then clamps — convenience for the common two-step pattern.
    nonisolated static func expandAndClamp(_ rect: CGRect, by factor: Double) -> CGRect {
        clamp(expand(rect, by: factor))
    }

    // MARK: - Coordinate Mapping

    /// Maps a bounding box that is **relative to `roi`** back to full-image Vision coords.
    ///
    /// Vision sets `regionOfInterest` so detections are normalised to the ROI:
    /// ```
    /// global.x = roi.x + det.x × roi.w
    /// global.y = roi.y + det.y × roi.h
    /// global.w = det.w × roi.w
    /// global.h = det.h × roi.h
    /// ```
    nonisolated static func toGlobal(detRect: CGRect, roi: CGRect) -> CGRect {
        CGRect(
            x:      roi.origin.x + detRect.origin.x * roi.width,
            y:      roi.origin.y + detRect.origin.y * roi.height,
            width:  detRect.width  * roi.width,
            height: detRect.height * roi.height
        )
    }

    // MARK: - ROI Derivation

    /// Derives the working ROI from the **locked hoop bounding box**.
    ///
    /// Typical call: `deriveROI(fromLockedHoop: debugState.lockedHoopRect!, expandFactor: 2.2)`
    nonisolated static func deriveROI(fromLockedHoop rect: CGRect,
                          expandFactor: Double = 2.2) -> CGRect {
        expandAndClamp(rect, by: expandFactor)
    }

    /// Derives the working ROI from a **user-drawn selection** (Vision coords).
    ///
    /// 1. Picks the highest-confidence hoop detection overlapping `userROI`.
    /// 2. Expands it by `expandFactor` and clamps.
    /// 3. Falls back to expanding `userROI` directly if no hoop was found.
    nonisolated static func deriveROI(from detections: [Detection],
                          userROI:         CGRect,
                          expandFactor:    Double = 2.2) -> CGRect {
        let bestHoop = detections
            .filter { $0.label == "Basketball Hoop" && $0.rectNormalized.intersects(userROI) }
            .max { $0.confidence < $1.confidence }

        if let hoop = bestHoop {
            return expandAndClamp(hoop.rectNormalized, by: expandFactor)
        }
        return expandAndClamp(userROI, by: expandFactor)
    }
}
