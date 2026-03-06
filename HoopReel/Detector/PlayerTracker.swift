import Foundation
import CoreGraphics
import CoreVideo
import Vision

// MARK: - PlayerTracker

/// Tracks a single user-selected player across video frames.
///
/// Uses `VNTrackObjectRequest` as the primary tracker and falls back to
/// body-pose + color-histogram re-identification when tracking confidence drops.
final class PlayerTracker: @unchecked Sendable {

    // MARK: Configuration

    /// Minimum histogram distance to accept a re-identification match (lower = stricter).
    var reidentificationThreshold: Float = 0.45

    /// Below this tracking confidence, attempt re-identification.
    var trackingConfidenceMin: Float = 0.3

    /// Minimum joint confidence for body-pose detection.
    var bodyPoseConfidenceMin: Float = 0.1

    /// If the tracked box jumps more than this (normalized), treat as scene cut.
    var sceneJumpThreshold: Double = 0.30

    // MARK: State

    private(set) var isInitialized = false
    private var templateHistogram: [Float] = []
    private var sequenceHandler: VNSequenceRequestHandler?
    private var lastObservation: VNDetectedObjectObservation?
    private var lastBox: CGRect = .zero  // top-left normalized

    // MARK: - Public API

    /// Initialize tracking from a user tap point.
    ///
    /// Runs body-pose detection to find all people, picks the one closest to
    /// `tapPoint`, extracts a color histogram template, and initializes
    /// the Vision object tracker.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The frame where the user tapped.
    ///   - tapPoint:    Normalized CGPoint (top-left origin) where user tapped.
    /// - Returns: The initial `TrackedPlayer`, or `nil` if no person found.
    func initializeFromTap(
        pixelBuffer: CVPixelBuffer,
        tapPoint: CGPoint
    ) throws -> TrackedPlayer? {

        // 1. Detect all body poses
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([poseRequest])

        guard let observations = poseRequest.results, !observations.isEmpty else {
            return nil
        }

        // 2. Find the person closest to the tap point
        var bestObs: VNHumanBodyPoseObservation?
        var bestDist: CGFloat = .infinity
        var bestBox: CGRect = .zero

        for obs in observations {
            guard let box = TrackedPlayer.boundingBox(
                from: obs,
                confidenceThreshold: bodyPoseConfidenceMin
            ) else { continue }

            let center = CGPoint(x: box.midX, y: box.midY)
            let dist = hypot(center.x - tapPoint.x, center.y - tapPoint.y)
            if dist < bestDist {
                bestDist = dist
                bestObs  = obs
                bestBox  = box
            }
        }

        guard bestObs != nil else { return nil }

        // 3. Extract color histogram template
        templateHistogram = TrackedPlayer.computeHistogram(
            pixelBuffer: pixelBuffer,
            region: bestBox
        )

        // 4. Initialize Vision tracker with the detected bounding box.
        // Convert top-left box to Vision coords (bottom-left origin).
        let visionBox = CGRect(
            x:      bestBox.origin.x,
            y:      1 - bestBox.origin.y - bestBox.height,
            width:  bestBox.width,
            height: bestBox.height
        )
        let detectedObj = VNDetectedObjectObservation(boundingBox: visionBox)
        lastObservation = detectedObj
        sequenceHandler = VNSequenceRequestHandler()
        lastBox = bestBox
        isInitialized = true

        return TrackedPlayer(
            id: UUID(),
            boundingBox: bestBox,
            colorHistogram: templateHistogram,
            trackingConfidence: 1.0,
            isTrackingActive: true
        )
    }

    /// Process a single video frame: track the selected player.
    ///
    /// - Returns: Updated `TrackedPlayer`, or `nil` if player is lost this frame.
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        timeSeconds: Double
    ) throws -> TrackedPlayer? {
        guard isInitialized,
              let seqHandler = sequenceHandler,
              let prevObs = lastObservation else {
            return nil
        }

        // 1. Try Vision object tracking
        let trackRequest = VNTrackObjectRequest(detectedObjectObservation: prevObs)
        trackRequest.trackingLevel = .fast

        do {
            try seqHandler.perform([trackRequest], on: pixelBuffer, orientation: .up)
        } catch {
            // Tracking failed — attempt re-id
            return try reidentify(pixelBuffer: pixelBuffer)
        }

        guard let result = trackRequest.results?.first as? VNDetectedObjectObservation else {
            return try reidentify(pixelBuffer: pixelBuffer)
        }

        let confidence = Float(result.confidence)

        // Convert Vision box to top-left
        let vBox = result.boundingBox
        let topLeftBox = CGRect(
            x:      vBox.origin.x,
            y:      1 - vBox.origin.y - vBox.height,
            width:  vBox.width,
            height: vBox.height
        )

        // Scene jump detection
        let jump = hypot(topLeftBox.midX - lastBox.midX, topLeftBox.midY - lastBox.midY)
        if jump > sceneJumpThreshold {
            // Likely a camera cut — try re-id
            return try reidentify(pixelBuffer: pixelBuffer)
        }

        // 2. Check confidence
        if confidence < trackingConfidenceMin {
            // Low confidence — attempt re-identification
            if let reidentified = try reidentify(pixelBuffer: pixelBuffer) {
                return reidentified
            }
            // Re-id failed but tracking still has something — use it
        }

        // 3. Accept tracking result
        lastObservation = result
        lastBox = topLeftBox

        return TrackedPlayer(
            id: UUID(),
            boundingBox: topLeftBox,
            colorHistogram: templateHistogram,
            trackingConfidence: confidence,
            isTrackingActive: true
        )
    }

    /// Reset all tracking state.
    func reset() {
        isInitialized    = false
        templateHistogram = []
        sequenceHandler  = nil
        lastObservation  = nil
        lastBox          = .zero
    }

    // MARK: - Private: Re-identification

    /// Attempts to re-identify the tracked player using body-pose detection
    /// and color histogram matching.
    private func reidentify(pixelBuffer: CVPixelBuffer) throws -> TrackedPlayer? {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([poseRequest])

        guard let observations = poseRequest.results, !observations.isEmpty else {
            return nil
        }

        var bestMatch: (box: CGRect, dist: Float)?

        for obs in observations {
            guard let box = TrackedPlayer.boundingBox(
                from: obs,
                confidenceThreshold: bodyPoseConfidenceMin
            ) else { continue }

            let hist = TrackedPlayer.computeHistogram(
                pixelBuffer: pixelBuffer,
                region: box
            )
            let dist = TrackedPlayer.histogramDistance(templateHistogram, hist)

            if dist < reidentificationThreshold {
                if bestMatch == nil || dist < bestMatch!.dist {
                    bestMatch = (box, dist)
                }
            }
        }

        guard let match = bestMatch else { return nil }

        // Re-initialize tracker with the matched box
        let visionBox = CGRect(
            x:      match.box.origin.x,
            y:      1 - match.box.origin.y - match.box.height,
            width:  match.box.width,
            height: match.box.height
        )
        let newObs = VNDetectedObjectObservation(boundingBox: visionBox)
        lastObservation = newObs
        sequenceHandler = VNSequenceRequestHandler()
        lastBox = match.box

        return TrackedPlayer(
            id: UUID(),
            boundingBox: match.box,
            colorHistogram: templateHistogram,
            trackingConfidence: 1.0 - match.dist,
            isTrackingActive: true
        )
    }
}
