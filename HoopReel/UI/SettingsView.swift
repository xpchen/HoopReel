import SwiftUI

// MARK: - SettingsView

/// Presented as a sheet from ContentView.
/// All three parameters are persisted to UserDefaults via @AppStorage so that
/// ContentView can read the same keys and react to changes automatically.
struct SettingsView: View {

    @EnvironmentObject private var langMgr: LanguageManager
    private func t(_ key: String) -> String { langMgr.tr(key) }

    @AppStorage("preSeconds")      var preSeconds:      Double = 4.0
    @AppStorage("postSeconds")     var postSeconds:     Double = 2.0
    @AppStorage("mergeGapSeconds") var mergeGapSeconds: Double = 2.0

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // ── Clip timing ────────────────────────────────────────────────
                Section {
                    DoubleStepper(
                        label: t("pre_buffer"),
                        value: $preSeconds,
                        step: 0.5, min: 0.5, max: 15
                    )
                    DoubleStepper(
                        label: t("post_buffer"),
                        value: $postSeconds,
                        step: 0.5, min: 0.5, max: 15
                    )
                    DoubleStepper(
                        label: t("merge_gap"),
                        value: $mergeGapSeconds,
                        step: 0.5, min: 0.0, max: 15
                    )
                } header: {
                    Text(verbatim: t("clip_timing_section"))
                } footer: {
                    Text(verbatim: t("clip_timing_footer"))
                }

                // ── Language ───────────────────────────────────────────────────
                Section {
                    Picker(t("language_section"), selection: $langMgr.storedLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(verbatim: lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(verbatim: t("language_section"))
                }

                // ── Reset ──────────────────────────────────────────────────────
                Section {
                    Button(t("reset_defaults")) {
                        preSeconds      = EventEngine.defaultPre
                        postSeconds     = EventEngine.defaultPost
                        mergeGapSeconds = EventEngine.defaultMergeGap
                    }
                    .foregroundStyle(.orange)
                }
            }
            .navigationTitle(t("settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - DoubleStepper

/// A form row showing a label, formatted current value, and a Stepper.
private struct DoubleStepper: View {
    let label: String
    @Binding var value: Double
    let step:  Double
    let min:   Double
    let max:   Double

    var body: some View {
        HStack {
            Text(verbatim: label)
            Spacer()
            Text(String(format: "%.1f s", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Stepper("", value: $value, in: min...max, step: step)
                .labelsHidden()
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(LanguageManager())
}
