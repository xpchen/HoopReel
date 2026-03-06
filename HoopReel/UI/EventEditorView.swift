import SwiftUI
import AVFoundation
import AVKit

// MARK: - EventEditorView

/// Sheet for reviewing, editing, and previewing detected make events.
/// Creates its own AVPlayer from `videoURL` so it is independent of ContentView's player.
struct EventEditorView: View {

    @Binding var events:     [Event]
    @Binding var clipRanges: [ClipRange]

    var videoURL: URL?                      // used to create localPlayer on appear
    var onChanged: () async -> Void

    // MARK: Language

    @EnvironmentObject private var langMgr: LanguageManager
    private func t(_ key: String) -> String { langMgr.tr(key) }

    // MARK: Local state

    @State private var localPlayer: AVPlayer? = nil
    @State private var showAddSheet = false
    @State private var addTimeText  = ""
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>? = nil
    @State private var showAlert = false
    @State private var alertMsg  = ""

    @Environment(\.dismiss) private var dismiss

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                // ── Embedded player ──────────────────────────────────────────
                if let p = localPlayer {
                    Section {
                        VideoPlayer(player: p)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }
                statsSection
                eventSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(t("event_editor_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("close")) { stopPreview(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { addTimeText = ""; showAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) { addMakeSheet }
        .alert(t("alert_title"), isPresented: $showAlert) {
            Button(t("alert_ok"), role: .cancel) {}
        } message: {
            Text(verbatim: alertMsg)
        }
        .onAppear {
            if let url = videoURL {
                localPlayer = AVPlayer(url: url)
            }
        }
        .onDisappear {
            stopPreview()
            localPlayer?.pause()
            localPlayer = nil
        }
    }

    // MARK: - Sections

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                statCell("\(events.count)", t("events_label"))
                Divider().frame(height: 32)
                statCell("\(clipRanges.count)", t("clips_label"))
                Divider().frame(height: 32)
                let total = clipRanges.reduce(0) { $0 + $1.duration }
                statCell(String(format: "%.1f s", total), t("total_duration_label"))
            }

            if isPreviewing {
                Button(role: .destructive, action: stopPreview) {
                    Label(t("stop_preview"), systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .tint(.red)
            } else {
                Button(action: startPreviewAll) {
                    Label(t("preview_all"), systemImage: "play.rectangle.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(events.isEmpty || localPlayer == nil)
            }
        }
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value).font(.title3.bold()).monospacedDigit()
            Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var eventSection: some View {
        Section(String(format: t("make_events_section"), sortedEvents.count)) {
            ForEach(sortedEvents) { event in
                eventRow(event)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteEvent(event) } label: {
                            Label(t("delete"), systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func eventBadgeColor(_ event: Event) -> Color {
        switch event.type {
        case "gain": return .green
        case "loss": return .red
        default:     return .orange
        }
    }

    private func eventTypeLabel(_ event: Event) -> String {
        switch event.type {
        case "gain": return t("possession_gain")
        case "loss": return t("possession_loss")
        default:     return "Make"
        }
    }

    private func eventRow(_ event: Event) -> some View {
        let idx = (sortedEvents.firstIndex { $0.id == event.id } ?? 0) + 1
        return HStack(spacing: 10) {
            Text("\(idx)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(eventBadgeColor(event)).clipShape(Circle())

            Button { previewEvent(event) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(verbatim: formatTime(event.time)).font(.body.monospacedDigit()).foregroundStyle(.primary)
                        if event.type != "make" {
                            Text(eventTypeLabel(event))
                                .font(.caption2.bold())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(eventBadgeColor(event).opacity(0.2))
                                .foregroundStyle(eventBadgeColor(event))
                                .cornerRadius(3)
                        }
                    }
                    Text(verbatim: t("tap_to_preview_3s")).font(.caption2).foregroundStyle(.orange)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Button { adjust(event, -0.1) } label: {
                    Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).disabled(event.time < 0.1)

                Button { adjust(event, +0.1) } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Add Make sheet

    private var addMakeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(t("add_time_placeholder"), text: $addTimeText)
                        .keyboardType(.decimalPad)
                } header: { Text(verbatim: t("input_time_header")) }
                  footer: { Text(verbatim: t("input_time_footer")) }
            }
            .navigationTitle(t("add_make_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("cancel")) { showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("add")) { commitAdd() }
                        .disabled(addTimeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Mutations

    private var sortedEvents: [Event] { events.sorted { $0.time < $1.time } }

    private func deleteEvent(_ event: Event) {
        withAnimation { events.removeAll { $0.id == event.id } }
        Task { await onChanged() }
    }

    private func adjust(_ event: Event, _ delta: Double) {
        guard let idx = events.firstIndex(where: { $0.id == event.id }) else { return }
        let newTime = max(0, round((event.time + delta) * 10) / 10)
        if let c = events.first(where: { $0.id != event.id && abs($0.time - newTime) < 0.3 }) {
            alertMsg = String(format: t("conflict_too_close"), formatTime(c.time))
            showAlert = true; return
        }
        events[idx] = Event(id: event.id, time: newTime, type: event.type)
        Task { await onChanged() }
    }

    private func commitAdd() {
        guard let secs = parseTime(addTimeText), secs >= 0 else {
            showAddSheet = false
            alertMsg = t("invalid_time_format")
            showAlert = true; return
        }
        if let c = events.first(where: { abs($0.time - secs) < 0.3 }) {
            showAddSheet = false
            alertMsg = String(format: t("conflict_cancelled"), formatTime(c.time))
            showAlert = true; return
        }
        withAnimation { events.append(Event(time: secs, type: "make")) }
        showAddSheet = false
        Task { await onChanged() }
    }

    // MARK: - Preview

    /// Seek with completion handler (waits for seek to land), then play.
    private func seekAndPlay(_ player: AVPlayer, to seconds: Double) async {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                cont.resume()
            }
        }
        player.play()
    }

    private func previewEvent(_ event: Event) {
        guard let player = localPlayer else { return }
        stopPreview()
        previewTask = Task {
            await seekAndPlay(player, to: event.time)
            do { try await Task.sleep(for: .seconds(1.5)) } catch {}
            player.pause()
        }
    }

    private func startPreviewAll() {
        guard let player = localPlayer, !events.isEmpty else { return }
        isPreviewing = true
        let list = sortedEvents
        previewTask = Task {
            for event in list {
                guard !Task.isCancelled else { break }
                await seekAndPlay(player, to: event.time)
                do {
                    try await Task.sleep(for: .seconds(1.5))
                    player.pause()
                    try await Task.sleep(for: .seconds(0.4))
                } catch { break }
            }
            isPreviewing = false
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        localPlayer?.pause()
        isPreviewing = false
    }

    // MARK: - Formatting

    private func formatTime(_ s: Double) -> String {
        let s = max(0, s); let m = Int(s) / 60
        return String(format: "%02d:%05.2f", m, s - Double(m * 60))
    }

    private func parseTime(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains(":") {
            let p = t.split(separator: ":", maxSplits: 1).map(String.init)
            guard p.count == 2, let m = Double(p[0]), let s = Double(p[1]) else { return nil }
            return m * 60 + s
        }
        return Double(t)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var events: [Event] = [
        Event(time: 12.3, type: "make"), Event(time: 45.6, type: "make"),
    ]
    @Previewable @State var clips: [ClipRange] = [ClipRange(start: 8.3, end: 18.3)]
    EventEditorView(events: $events, clipRanges: $clips, videoURL: nil) {}
        .environmentObject(LanguageManager())
}
