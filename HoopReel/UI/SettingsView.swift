import SwiftUI

// MARK: - SettingsView

/// Presented as a sheet from ContentView.
/// All three parameters are persisted to UserDefaults via @AppStorage so that
/// ContentView can read the same keys and react to changes automatically.
struct SettingsView: View {

    @AppStorage("preSeconds")      var preSeconds:      Double = 4.0
    @AppStorage("postSeconds")     var postSeconds:     Double = 2.0
    @AppStorage("mergeGapSeconds") var mergeGapSeconds: Double = 2.0

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DoubleStepper(
                        label: "进攻前缓冲",
                        value: $preSeconds,
                        step: 0.5, min: 0.5, max: 15
                    )
                    DoubleStepper(
                        label: "进攻后缓冲",
                        value: $postSeconds,
                        step: 0.5, min: 0.5, max: 15
                    )
                    DoubleStepper(
                        label: "合并间隔",
                        value: $mergeGapSeconds,
                        step: 0.5, min: 0.0, max: 15
                    )
                } header: {
                    Text("片段时间参数（秒）")
                } footer: {
                    Text("调整后片段范围实时生效。合并间隔越大，相邻投篮越可能合并为一个片段。")
                }

                Section {
                    Button("恢复默认值") {
                        preSeconds      = EventEngine.defaultPre
                        postSeconds     = EventEngine.defaultPost
                        mergeGapSeconds = EventEngine.defaultMergeGap
                    }
                    .foregroundStyle(.orange)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
            Text(label)
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
}
