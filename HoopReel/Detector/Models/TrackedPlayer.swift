import Foundation
import CoreGraphics
import CoreVideo
import Vision
import Accelerate

// MARK: - TrackedPlayer

/// Identity and state of the player being tracked across video frames.
struct TrackedPlayer: Sendable {
    let id: UUID
    var boundingBox: CGRect             // normalized, top-left origin [0,1]
    var colorHistogram: [Float]         // HSV histogram (3×16 = 48 bins)
    var trackingConfidence: Float       // 0..1 from VNTrackObjectRequest
    var isTrackingActive: Bool

    // MARK: - Bounding box from body pose joints

    /// Derives a bounding box from VNHumanBodyPoseObservation recognized points.
    /// Returns nil if no usable joints are found.
    static func boundingBox(
        from observation: VNHumanBodyPoseObservation,
        confidenceThreshold: Float = 0.1
    ) -> CGRect? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        let usable = points.values.filter { $0.confidence >= confidenceThreshold }
        guard !usable.isEmpty else { return nil }

        // Vision coords (bottom-left origin) — convert to top-left
        var minX: CGFloat = 1, maxX: CGFloat = 0
        var minY: CGFloat = 1, maxY: CGFloat = 0

        for pt in usable {
            let x = pt.location.x
            let y = 1 - pt.location.y  // flip to top-left origin

            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        // Add 10% padding
        let w = maxX - minX
        let h = maxY - minY
        let padX = w * 0.10
        let padY = h * 0.10

        return CGRect(
            x:      max(0, minX - padX),
            y:      max(0, minY - padY),
            width:  min(1, w + padX * 2),
            height: min(1, h + padY * 2)
        )
    }

    // MARK: - Color histogram

    /// Computes a simplified HSV color histogram from a region of a CVPixelBuffer.
    /// Region is in normalized top-left coords [0,1].
    /// Returns a 48-element histogram (H:16 bins, S:16 bins, V:16 bins).
    static func computeHistogram(pixelBuffer: CVPixelBuffer, region: CGRect) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [Float](repeating: 0, count: 48)
        }

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Map normalized region to pixel coords
        let x0 = max(0, Int(region.minX * CGFloat(width)))
        let y0 = max(0, Int(region.minY * CGFloat(height)))
        let x1 = min(width,  Int(region.maxX * CGFloat(width)))
        let y1 = min(height, Int(region.maxY * CGFloat(height)))

        guard x1 > x0 && y1 > y0 else {
            return [Float](repeating: 0, count: 48)
        }

        let bins = 16
        var hist = [Float](repeating: 0, count: bins * 3)
        var count: Float = 0

        // Sample every 2nd pixel for performance
        for row in Swift.stride(from: y0, to: y1, by: 2) {
            for col in Swift.stride(from: x0, to: x1, by: 2) {
                let offset = row * stride + col * 4  // BGRA
                let b = Float(ptr[offset])     / 255
                let g = Float(ptr[offset + 1]) / 255
                let r = Float(ptr[offset + 2]) / 255

                let (h, s, v) = rgbToHSV(r: r, g: g, b: b)

                let hBin = min(bins - 1, Int(h * Float(bins)))
                let sBin = min(bins - 1, Int(s * Float(bins)))
                let vBin = min(bins - 1, Int(v * Float(bins)))

                hist[hBin]          += 1
                hist[bins + sBin]   += 1
                hist[bins*2 + vBin] += 1
                count += 1
            }
        }

        // Normalize
        if count > 0 {
            for i in 0..<hist.count {
                hist[i] /= count
            }
        }

        return hist
    }

    /// Bhattacharyya distance between two histograms.
    /// 0 = identical, 1 = completely disjoint.
    static func histogramDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }

        var bc: Float = 0  // Bhattacharyya coefficient
        for i in 0..<a.count {
            bc += sqrtf(a[i] * b[i])
        }

        // distance = sqrt(1 - BC), clamped to [0, 1]
        let dist = sqrtf(max(0, 1 - bc))
        return min(1, dist)
    }

    // MARK: - RGB → HSV

    private static func rgbToHSV(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        let v = maxC

        guard delta > 0.001 else {
            return (0, 0, v)
        }

        let s = delta / maxC

        var h: Float
        if r >= maxC {
            h = (g - b) / delta
        } else if g >= maxC {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }

        h /= 6
        if h < 0 { h += 1 }

        return (h, s, v)
    }
}
