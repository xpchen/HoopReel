import Foundation

// MARK: - ExportMode

/// Whether to merge all clips into one highlight or export each clip separately.
enum ExportMode: String, CaseIterable, Identifiable {
    case highlight = "highlight"
    case clips     = "clips"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highlight: return "集锦"
        case .clips:     return "多段"
        }
    }
}

// MARK: - ExportPreset

/// Predefined clip-timing presets for the highlight exporter.
enum ExportPreset: String, CaseIterable, Identifiable {
    case quick     = "quick"
    case standard  = "standard"
    case cinematic = "cinematic"

    var id: String { rawValue }

    // MARK: Display

    var displayName: String {
        switch self {
        case .quick:     return "快剪"
        case .standard:  return "标准"
        case .cinematic: return "电影感"
        }
    }

    var subtitle: String {
        switch self {
        case .quick:     return "Quick"
        case .standard:  return "Standard"
        case .cinematic: return "Cinematic"
        }
    }

    // MARK: Timing

    /// Seconds of footage kept before the make event.
    var pre: Double {
        switch self {
        case .quick:     return 3.0
        case .standard:  return 4.0
        case .cinematic: return 5.0
        }
    }

    /// Seconds of footage kept after the make event.
    var post: Double {
        switch self {
        case .quick:     return 1.5
        case .standard:  return 2.0
        case .cinematic: return 3.0
        }
    }

    /// Adjacent clip ranges within this gap (seconds) are merged into one.
    var mergeGap: Double {
        switch self {
        case .quick:     return 1.5
        case .standard:  return 2.0
        case .cinematic: return 2.5
        }
    }

    // MARK: Convenience

    /// Human-readable parameter summary for display in the UI.
    var paramSummary: String {
        String(format: "前 %.1f s · 后 %.1f s · 合并 %.1f s", pre, post, mergeGap)
    }
}
