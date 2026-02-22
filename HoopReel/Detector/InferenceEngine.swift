import Foundation
import CoreGraphics

// MARK: - InferenceEngineProtocol

/// Runs object-detection inference on a single frame image.
/// Replace the placeholder implementation with a real CoreML model.
protocol InferenceEngineProtocol: Sendable {

    /// Runs detection on `image` and returns a `DetectionFrame`.
    ///
    /// - Parameters:
    ///   - image:      frame image (should match the model's expected input size).
    ///   - frameIndex: monotonically increasing frame counter.
    ///   - timestamp:  wall-clock time of this frame in the source video (seconds).
    func infer(
        image:      CGImage,
        frameIndex: Int,
        timestamp:  Double
    ) async throws -> DetectionFrame
}

// MARK: - CoreMLInferenceEngine (Placeholder)

/// Placeholder implementation that returns random detections.
/// Replace `runModel(_:)` with actual CoreML inference once a trained
/// `.mlpackage` (ball + hoop detection, e.g. YOLOv8-nano) is available.
///
/// Expected model I/O
/// ──────────────────
///  Input:  "image"   — CVPixelBuffer 416×416 RGB
///  Output: "boxes"   — [N × 6] Float32  (x, y, w, h, conf, class_id)
///          "classes" — optional class labels
///
final class CoreMLInferenceEngine: InferenceEngineProtocol {

    // MARK: Constants

    /// Class index assigned to the basketball in the trained model.
    static let ballClassID:  Int = 0
    /// Class index assigned to the hoop/rim in the trained model.
    static let hoopClassID:  Int = 1
    /// Minimum detection confidence to report a box.
    static let minConfidence: Float = 0.40

    // MARK: - InferenceEngineProtocol

    func infer(
        image:      CGImage,
        frameIndex: Int,
        timestamp:  Double
    ) async throws -> DetectionFrame {
        // ── TODO: Replace this stub with real CoreML inference ──────────────
        // 1. Convert CGImage → CVPixelBuffer (resize to model input size)
        // 2. Call mlModel.prediction(input:)
        // 3. Decode output tensor → [BBox] split by class_id
        // ────────────────────────────────────────────────────────────────────

        let detections = runModel(image)

        let ball    = detections.first(where: { $0.classID == Self.ballClassID })
                        .map { BBox(x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                                    confidence: $0.confidence) }
        let hoop    = detections.first(where: { $0.classID == Self.hoopClassID })
                        .map { BBox(x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                                    confidence: $0.confidence) }

        return DetectionFrame(
            frameIndex: frameIndex,
            timestamp:  timestamp,
            ball:       ball,
            hoop:       hoop,
            players:    []
        )
    }

    // MARK: - Private / Stub

    private struct RawDetection {
        let classID:    Int
        let x, y, w, h: Float
        let confidence: Float
    }

    /// Stub: returns empty detections.  Replace with MLModel call.
    private func runModel(_ image: CGImage) -> [RawDetection] {
        // Real implementation:
        //   let input = try YOLOInput(image: pixelBuffer)
        //   let output = try mlModel.prediction(input: input)
        //   return decode(output.boxes)
        return []
    }
}
