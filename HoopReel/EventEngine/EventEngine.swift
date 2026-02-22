import Foundation

// MARK: - EventEngine

/// Pure-logic namespace: loads JSON events and converts them to merged clip ranges.
///
/// Clip-range rules
/// ────────────────
///  • Each "make" produces [t − pre, t + post] clamped to [0, videoDuration].
///  • Event times exceeding videoDuration are automatically clamped before
///    range calculation, so out-of-bounds events still contribute valid clips.
///  • Consecutive ranges whose gap ≤ mergeGap are merged into one.
enum EventEngine {

    // MARK: Default Configuration

    static let defaultPre:      Double = 4.0
    static let defaultPost:     Double = 2.0
    static let defaultMergeGap: Double = 2.0

    // MARK: - Load

    /// Decodes events from a JSON file in the main bundle.
    /// - Parameter resource: filename without extension (default "makes.sample").
    static func loadEvents(named resource: String = "makes.sample") -> [Event] {
        guard
            let url   = Bundle.main.url(forResource: resource, withExtension: "json"),
            let data  = try? Data(contentsOf: url),
            let items = try? JSONDecoder().decode([Event].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - Filter

    /// Keeps only "make" events whose time falls within [0, videoDuration].
    /// Returns the valid subset; caller can derive droppedCount by comparison.
    static func filterValid(events: [Event], videoDuration: Double) -> [Event] {
        events.filter { $0.type == "make" && $0.time >= 0 && $0.time <= videoDuration }
    }

    // MARK: - Compute

    /// Converts a list of events into merged, clamped clip ranges.
    ///
    /// Example (pre=4, post=2, mergeGap=2):
    ///   makes at 35.2 s → [31.2, 37.2]
    ///   makes at 37.8 s → [33.8, 39.8]   ← overlaps; merged → [31.2, 39.8]
    ///
    /// - Parameters:
    ///   - events:        raw event list (non-"make" types are ignored).
    ///   - videoDuration: total video length in seconds (upper clamp bound).
    ///   - pre:           seconds before each make (default 4.0).
    ///   - post:          seconds after each make (default 2.0).
    ///   - mergeGap:      merge consecutive ranges within this gap (default 2.0).
    static func computeClipRanges(
        from events:       [Event],
        videoDuration:     Double,
        pre:      Double = defaultPre,
        post:     Double = defaultPost,
        mergeGap: Double = defaultMergeGap
    ) -> [ClipRange] {

        // Clamp event times to [0, videoDuration] so out-of-range events still
        // contribute a clip at the boundary rather than being silently dropped.
        let times = events
            .filter { $0.type == "make" }
            .map    { max(0, min(videoDuration, $0.time)) }
            .sorted ()

        guard !times.isEmpty else { return [] }

        // 1. Raw ranges — one per make, clamped to video bounds
        let raw: [ClipRange] = times.map {
            ClipRange(
                start: max(0,             $0 - pre),
                end:   min(videoDuration, $0 + post)
            )
        }

        // 2. Merge ranges that overlap or whose gap ≤ mergeGap
        var merged: [ClipRange] = []
        for r in raw {
            if let last = merged.last, r.start <= last.end + mergeGap {
                merged[merged.count - 1] = ClipRange(
                    start: last.start,
                    end:   max(last.end, r.end)
                )
            } else {
                merged.append(r)
            }
        }

        return merged.filter { $0.duration > 0 }
    }

    /// One ClipRange per make event, **no merging**.
    /// Used for "多段" export so each shot gets its own file.
    static func computeRawClipRanges(
        from events:   [Event],
        videoDuration: Double,
        pre:  Double = defaultPre,
        post: Double = defaultPost
    ) -> [ClipRange] {
        events
            .filter { $0.type == "make" }
            .map    { max(0, min(videoDuration, $0.time)) }
            .sorted()
            .map {
                ClipRange(
                    start: max(0,             $0 - pre),
                    end:   min(videoDuration, $0 + post)
                )
            }
            .filter { $0.duration > 0 }
    }
}
