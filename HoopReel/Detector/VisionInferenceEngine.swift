import Foundation
import CoreML
import Vision
import CoreVideo

// MARK: - VisionInferenceEngine

/// Runs HoopDetector.mlpackage through the Vision framework.
///
/// When `roiRectNormalized` is provided to `detect(…)`, Vision's
/// `regionOfInterest` restricts inference to that crop.  Bounding boxes
/// in the returned `Detection` values are **always in full-image Vision
/// coordinates** (bottom-left origin, 0–1) — the ROI-relative coordinates
/// from Vision are mapped back via `RoiMapper.toGlobal`.
final class VisionInferenceEngine: @unchecked Sendable {

    // Written once in init, only read afterwards → nonisolated(unsafe) is safe.
    nonisolated(unsafe) private var vnModel: VNCoreMLModel
    nonisolated(unsafe) private var hasLoggedLabels = false

    /// Classes we retain from the model output.
    nonisolated static let interestingLabels: Set<String> = ["Basketball", "Basketball Hoop"]

    /// Per-class minimum confidence thresholds.  Observations below these are
    /// discarded before reaching the rule engine, cutting false-positive triggers.
    nonisolated static let minConfidence: [String: Double] = [
        "Basketball":      0.15,
        "Basketball Hoop": 0.35,
    ]

    // MARK: Init

    /// Loads `HoopDetector.mlpackage` and wraps it in a `VNCoreMLModel`.
    /// Throws if the model asset is missing or incompatible.
    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all          // ANE → GPU → CPU fallback
        let detector = try HoopDetector(configuration: config)
        self.vnModel = try VNCoreMLModel(for: detector.model)
    }

    // MARK: - Public API

    /// Runs detection on a single pixel buffer.
    ///
    /// - Parameters:
    ///   - pixelBuffer:         Raw decoded video frame (any size; Vision resizes).
    ///   - timeSeconds:         Presentation timestamp stamped onto each `Detection`.
    ///   - roiRectNormalized:   Optional ROI in **Vision coords** (bottom-left origin,
    ///                          0–1).  When set, only this region is processed and
    ///                          returned bounding boxes are mapped to full-image coords.
    /// - Returns: `Detection` array with `rectNormalized` in full-image Vision coords.
    nonisolated func detect(
        pixelBuffer:       CVPixelBuffer,
        timeSeconds:       Double,
        roiRectNormalized: CGRect? = nil
    ) throws -> [Detection] {

        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        // Clamp once; reuse the same value for both regionOfInterest and mapping.
        let effectiveROI = roiRectNormalized.map { RoiMapper.clamp($0) }
        if let roi = effectiveROI {
            request.regionOfInterest = roi
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation:   .up,
            options:       [:]
        )
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            return []
        }

        // ── Debug: log all label names on the very first inference ──────────
        if !hasLoggedLabels {
            let unique = Set(observations.flatMap { $0.labels.map(\.identifier) }).sorted()
            print("──────────────────────────────────────────")
            print("[HoopReel] First-inference labels (\(observations.count) detections):")
            for l in unique { print("  • \(l)") }
            if observations.isEmpty { print("  ⚠️  No detections – check model / input") }
            print("──────────────────────────────────────────")
            hasLoggedLabels = true
        }

        // ── Build Detection array ────────────────────────────────────────────
        var detections: [Detection] = []
        for obs in observations {
            guard let top = obs.labels.first,
                  Self.interestingLabels.contains(top.identifier),
                  Double(top.confidence) >= Self.minConfidence[top.identifier, default: 0]
            else { continue }

            // When a ROI was used, Vision returns coords relative to the ROI.
            // Map back to full-image Vision coordinates.
            let bbox: CGRect
            if let roi = effectiveROI {
                bbox = RoiMapper.toGlobal(detRect: obs.boundingBox, roi: roi)
            } else {
                bbox = obs.boundingBox      // already in full-image coords
            }

            detections.append(Detection(
                label:          top.identifier,
                confidence:     Double(top.confidence),
                rectNormalized: bbox,       // Vision coords, bottom-left origin
                timeSeconds:    timeSeconds
            ))
        }

        return detections
    }
}
