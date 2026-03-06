import SwiftUI
import Foundation
import Combine

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable, Identifiable {
    case system  = "system"
    case zhHans  = "zh-Hans"
    case en      = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  return "跟随系统 / Auto"
        case .zhHans:  return "简体中文"
        case .en:      return "English"
        }
    }
}

// MARK: - LanguageManager

/// Manages app-level language selection. Inject as @EnvironmentObject at the root.
class LanguageManager: ObservableObject {

    @AppStorage("appLanguage") var storedLanguage: String = AppLanguage.system.rawValue {
        didSet { objectWillChange.send() }
    }

    var currentLanguage: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .system
    }

    /// Whether the active language resolves to English.
    var isEnglish: Bool {
        switch currentLanguage {
        case .en:     return true
        case .zhHans: return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? ""
            return !preferred.hasPrefix("zh")
        }
    }

    /// Returns the localized string for `key`.
    /// Falls back to the Chinese string, then the key itself.
    func tr(_ key: String) -> String {
        let col = isEnglish ? "en" : "zh"
        return L10nTable.table[key]?[col]
            ?? L10nTable.table[key]?["zh"]
            ?? key
    }
}

// MARK: - L10n Table

enum L10nTable {
    static let table: [String: [String: String]] = [

        // ── General ────────────────────────────────────────────────────────────
        "alert_title":          ["zh": "提示",          "en": "Notice"],
        "alert_ok":             ["zh": "确定",          "en": "OK"],
        "close":                ["zh": "关闭",          "en": "Close"],
        "done":                 ["zh": "完成",          "en": "Done"],
        "reset_defaults":       ["zh": "恢复默认值",     "en": "Reset Defaults"],
        "seconds_unit":         ["zh": "秒",            "en": "s"],

        // ── Hero / Picker ──────────────────────────────────────────────────────
        "subtitle":             ["zh": "自动生成投篮精彩集锦",
                                 "en": "Auto Basketball Highlight Generator"],
        "loading":              ["zh": "加载中…",       "en": "Loading…"],
        "select_video":         ["zh": "选择比赛视频",   "en": "Select Video"],
        "reselect_video":       ["zh": "重新选择视频",   "en": "Change Video"],

        // ── Player ─────────────────────────────────────────────────────────────
        "preview_label":        ["zh": "预览",          "en": "Preview"],

        // ── Detection controls ─────────────────────────────────────────────────
        "debug_overlay":        ["zh": "调试叠加层",     "en": "Debug Overlay"],
        "stop_detection":       ["zh": "停止检测",       "en": "Stop"],
        "preview_10s":          ["zh": "预览 (10s)",     "en": "Preview (10s)"],
        "detect_10s":           ["zh": "检测 (10s)",     "en": "Detect (10s)"],
        "auto_detect_full":     ["zh": "自动检测（全片）", "en": "Auto Detect (Full)"],

        // ── Detection progress ─────────────────────────────────────────────────
        "detecting_makes":      ["zh": "检测进球中",     "en": "Detecting makes"],
        "detecting":            ["zh": "检测中",         "en": "Detecting"],
        // %d = count
        "detected_makes_count": ["zh": "已检测到 %d 个进球",
                                 "en": "Detected %d make(s)"],
        "detection_cancelled":  ["zh": "检测已取消",     "en": "Detection cancelled"],
        // %@ = error description
        "detection_failed":     ["zh": "检测失败：%@",   "en": "Detection failed: %@"],
        // %d = count
        "detection_complete":   ["zh": "完成：检测到 %d 个进球",
                                 "en": "Done: %d make(s) detected"],
        "detection_no_makes":   ["zh": "完成：未检测到进球（尝试调整参数或视频）",
                                 "en": "Done: no makes found (try adjusting settings or video)"],
        "switched_video_hint":  ["zh": "已切换视频，请重新 Auto Detect",
                                 "en": "Video changed — run Auto Detect again"],

        // ── Info section ───────────────────────────────────────────────────────
        "please_select_video":  ["zh": "请选择视频",     "en": "Please select a video"],
        "no_events_hint":       ["zh": "尚未生成事件：点击 Auto Detect 或导入 events.json",
                                 "en": "No events yet — tap Auto Detect or import events.json"],
        // %d = makes, %d = dropped
        "events_with_dropped":  ["zh": "%d 个进球事件 · 忽略超时：%d",
                                 "en": "%d make event(s) · %d out-of-range ignored"],
        // %d = makes
        "events_count":         ["zh": "%d 个进球事件",
                                 "en": "%d make event(s)"],
        // %d = clips, %@ = total seconds
        "clips_summary":        ["zh": "%d 个片段 · 合计约 %@ 秒",
                                 "en": "%d clip(s) · total ~%@ s"],

        // ── Event list section ─────────────────────────────────────────────────
        "event_list_title":     ["zh": "事件列表",       "en": "Event List"],
        // %d = count
        "event_list_subtitle":  ["zh": "%d 个进球 · 点击编辑 / 预览",
                                 "en": "%d make(s) · tap to edit / preview"],

        // ── Range list ─────────────────────────────────────────────────────────
        "merged_clips":         ["zh": "合并片段",       "en": "Merged Clips"],
        "duration_label":       ["zh": "时长",           "en": "Duration"],

        // ── Export progress ────────────────────────────────────────────────────
        // %f = 0–100
        "exporting_progress":   ["zh": "正在导出 %.0f%%",  "en": "Exporting %.0f%%"],
        "cancel_export":        ["zh": "取消导出",        "en": "Cancel Export"],
        "exporting":            ["zh": "导出中…",         "en": "Exporting…"],
        // %@ = error
        "export_failed":        ["zh": "导出失败：%@",    "en": "Export failed: %@"],
        "retry_export":         ["zh": "重新导出",        "en": "Retry Export"],
        "export_no_clips":      ["zh": "请先选择视频并确保有可用片段",
                                 "en": "Please select a video with available clips first"],

        // ── Multi-clip sheet ───────────────────────────────────────────────────
        // %d = count
        "exported_clips_title": ["zh": "导出片段（%d 个）",
                                 "en": "Exported Clips (%d)"],
        "share_all":            ["zh": "全部分享",        "en": "Share All"],

        // ── Preset / export mode ───────────────────────────────────────────────
        "export_mode":          ["zh": "导出模式",        "en": "Export Mode"],
        "export_preset":        ["zh": "导出预设",        "en": "Clip Preset"],
        // %d = count
        "export_clips_n":       ["zh": "导出 %d 段视频",  "en": "Export %d Clip(s)"],
        "generate_highlight":   ["zh": "生成精彩集锦",    "en": "Generate Highlight"],

        // ExportMode display names
        "mode_highlight":       ["zh": "集锦",            "en": "Highlight"],
        "mode_clips":           ["zh": "多段",            "en": "Clips"],

        // ExportPreset display names (keys match enum rawValue: quick / standard / cinematic)
        "preset_quick":         ["zh": "快剪",            "en": "Quick"],
        "preset_standard":      ["zh": "标准",            "en": "Standard"],
        "preset_cinematic":     ["zh": "电影感",          "en": "Cinematic"],

        // ── Detection mode (Player Tracking) ─────────────────────────────
        "mode_shot_detect":          ["zh": "投篮检测",                "en": "Shot Detection"],
        "mode_player_track":         ["zh": "球员追踪",                "en": "Player Tracking"],
        "select_player":             ["zh": "选择球员",                "en": "Select Player"],
        "reselect_player":           ["zh": "重新选择",                "en": "Reselect"],
        "start_tracking":            ["zh": "开始追踪",                "en": "Start Tracking"],
        "tap_player_hint":           ["zh": "点击画面中要追踪的球员",    "en": "Tap the player you want to track"],
        "possession_gain":           ["zh": "得球",                    "en": "Gain"],
        "possession_loss":           ["zh": "丢球",                    "en": "Loss"],
        "possession_has_ball":       ["zh": "持球",                    "en": "BALL"],
        "possession_no_ball":        ["zh": "无球",                    "en": "NO BALL"],
        "tracking_lost":             ["zh": "追踪丢失，尝试重新定位…",   "en": "Tracking lost, re-identifying…"],
        "gains_count":               ["zh": "得球 %d 次",              "en": "%d gain(s)"],
        "losses_count":              ["zh": "丢球 %d 次",              "en": "%d loss(s)"],
        "player_selected":           ["zh": "已选中球员",               "en": "Player selected"],
        "no_player_found":           ["zh": "未找到球员，请重新点击",     "en": "No player found. Try tapping again."],
        "tracking_complete":         ["zh": "完成：%d 得球 · %d 丢球",  "en": "Done: %d gain(s) · %d loss(s)"],
        "tracking_no_events":        ["zh": "完成：未检测到控球变化",     "en": "Done: no possession changes detected"],
        "detecting_possession":      ["zh": "追踪球员控球中",           "en": "Tracking possession"],
        "tracking_live_count":       ["zh": "得球 %d · 丢球 %d",       "en": "Gains %d · Losses %d"],
        "confirm_selection":         ["zh": "确认",                    "en": "Confirm"],
        "tap_to_reselect_hint":      ["zh": "可再次点击重新选择",         "en": "Tap again to reselect"],

        // ExportPreset subtitles
        "preset_quick_subtitle":     ["zh": "快速切换，节奏紧凑",
                                      "en": "Fast cuts, compact pacing"],
        "preset_standard_subtitle":  ["zh": "适合大多数场景",
                                      "en": "Suitable for most scenarios"],
        "preset_cinematic_subtitle": ["zh": "完整进攻回合，电影节奏",
                                      "en": "Full possession, cinematic pacing"],

        // ── Settings ───────────────────────────────────────────────────────────
        "settings_title":           ["zh": "设置",            "en": "Settings"],
        "clip_timing_section":      ["zh": "片段时间参数（秒）", "en": "Clip Timing (seconds)"],
        "clip_timing_footer":       ["zh": "调整后片段范围实时生效。合并间隔越大，相邻投篮越可能合并为一个片段。",
                                     "en": "Changes apply immediately. Larger merge gap combines nearby makes into one clip."],
        "pre_buffer":               ["zh": "进攻前缓冲",       "en": "Pre-roll"],
        "post_buffer":              ["zh": "进攻后缓冲",       "en": "Post-roll"],
        "merge_gap":                ["zh": "合并间隔",         "en": "Merge Gap"],

        // Language section
        "language_section":         ["zh": "语言",             "en": "Language"],
        "language_auto":            ["zh": "跟随系统 / Auto",  "en": "System Default"],
        "language_zh":              ["zh": "简体中文",          "en": "简体中文"],
        "language_en":              ["zh": "English",           "en": "English"],

        // ── Video load error ───────────────────────────────────────────────────
        // %@ = error description
        "video_load_failed":        ["zh": "视频加载失败：%@",
                                     "en": "Failed to load video: %@"],

        // ── EventEditorView ────────────────────────────────────────────────────
        "event_editor_title":       ["zh": "事件编辑",          "en": "Event Editor"],
        "events_label":             ["zh": "事件",              "en": "Events"],
        "clips_label":              ["zh": "片段",              "en": "Clips"],
        "total_duration_label":     ["zh": "总时长",            "en": "Total"],
        "stop_preview":             ["zh": "停止预览",          "en": "Stop Preview"],
        "preview_all":              ["zh": "预览全部",          "en": "Preview All"],
        // %d = count
        "make_events_section":      ["zh": "进球事件 (%d)",    "en": "Make Events (%d)"],
        "delete":                   ["zh": "删除",              "en": "Delete"],
        "tap_to_preview_3s":        ["zh": "点击预览 3 s",      "en": "Tap to preview 3 s"],
        "add_time_placeholder":     ["zh": "如：34.5 或 1:14.50",
                                     "en": "e.g. 34.5 or 1:14.50"],
        "input_time_header":        ["zh": "输入时间点（秒）",  "en": "Enter time (seconds)"],
        "input_time_footer":        ["zh": "支持格式：34.5 / 1:14 / 1:14.50",
                                     "en": "Formats: 34.5 / 1:14 / 1:14.50"],
        "add_make_title":           ["zh": "添加进球",          "en": "Add Make"],
        "cancel":                   ["zh": "取消",              "en": "Cancel"],
        "add":                      ["zh": "添加",              "en": "Add"],
        // %@ = conflicting time string
        "conflict_too_close":       ["zh": "与 %@ 相差不足 0.3 s，请重新调整。",
                                     "en": "Too close to %@ (< 0.3 s). Please adjust."],
        "conflict_cancelled":       ["zh": "与 %@ 相差不足 0.3 s，添加已取消。",
                                     "en": "Too close to %@ (< 0.3 s). Add cancelled."],
        "invalid_time_format":      ["zh": "时间格式无效，请输入如 34.5 或 1:14.50",
                                     "en": "Invalid format. Try 34.5 or 1:14.50"],

        // ── ExportPreset paramSummary ──────────────────────────────────────────
        // %.1f × 3 = pre, post, mergeGap
        "param_summary":            ["zh": "前 %.1f s · 后 %.1f s · 合并 %.1f s",
                                     "en": "Pre %.1f s · Post %.1f s · Merge %.1f s"],
    ]
}
