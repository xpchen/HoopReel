import Foundation

// MARK: - Localized display helpers for ExportMode

extension ExportMode {
    func localizedName(using mgr: LanguageManager) -> String {
        mgr.tr("mode_\(rawValue)")
    }
}

// MARK: - Localized display helpers for ExportPreset

extension ExportPreset {
    func localizedName(using mgr: LanguageManager) -> String {
        mgr.tr("preset_\(rawValue)")
    }

    func localizedSubtitle(using mgr: LanguageManager) -> String {
        mgr.tr("preset_\(rawValue)_subtitle")
    }

    /// Localized parameter summary: "前 4.0 s · 后 2.0 s · 合并 2.0 s" / "Pre 4.0 s · Post 2.0 s · Merge 2.0 s"
    func localizedParamSummary(using mgr: LanguageManager) -> String {
        String(format: mgr.tr("param_summary"), pre, post, mergeGap)
    }
}
