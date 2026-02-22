import Foundation

// MARK: - Event

/// A single event decoded from makes.sample.json (or produced by ShotDetector).
struct Event: Codable, Identifiable, Equatable {
    /// Stable SwiftUI identity; not encoded/decoded from JSON.
    var id: UUID = UUID()
    let time: Double   // seconds from video start
    let type: String   // "make" | future types

    enum CodingKeys: String, CodingKey {
        case time, type
    }
}

// MARK: - ClipRange

/// A closed time interval [start, end] in seconds, shared by
/// EventEngine (computation) and HighlightExporter (AVFoundation insertion).
struct ClipRange: Identifiable {
    var id: UUID = UUID()
    let start: Double
    let end:   Double

    var duration: Double { end - start }
}
