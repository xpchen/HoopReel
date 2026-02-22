import Foundation

// MARK: - ShotCandidate

/// A time window where the rule engine believes a successful shot occurred.
/// Multiple candidates may be produced; the caller filters by `confidence`.
struct ShotCandidate {
    let startFrame:  Int       // first frame where ball entered ShootingZone
    let peakFrame:   Int       // frame where through-hoop transition was detected
    let endFrame:    Int       // last frame in the detection window
    let confidence:  Float     // 0–1 composite score from rule engine

    /// Time of the shot peak in seconds (canonical timestamp for the Event).
    let timestamp: Double
}

extension ShotCandidate {
    /// Converts a high-confidence candidate into an Event for EventEngine.
    func toEvent(confidenceThreshold: Float = 0.6) -> Event? {
        guard confidence >= confidenceThreshold else { return nil }
        return Event(time: timestamp, type: "make")
    }
}
