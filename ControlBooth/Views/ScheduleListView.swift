import SwiftUI

struct ScheduleListView: View {
    @Environment(ScheduledEventStore.self) private var eventStore
    @Environment(PipelineStore.self) private var pipelineStore
    @Environment(Scheduler.self) private var scheduler
    @Environment(PipelineRunner.self) private var runner
    @Binding var selectedID: Int64?
    @State private var errorMessage: String?

    var body: some View {
        List(selection: $selectedID) {
            ForEach(eventStore.events) { event in
                ScheduleEventRow(event: event, pipelineName: pipelineName(for: event))
                    .tag(event.id ?? -1)
            }
        }
        .navigationTitle("Schedule")
        .toolbar {
            ToolbarItem {
                Button {
                    addEvent()
                } label: {
                    Label("Add Event", systemImage: "plus")
                }
                .help("Add a new scheduled event")
                .disabled(pipelineStore.pipelines.isEmpty)
            }
        }
        .alert("Schedule Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func pipelineName(for event: ScheduledEvent) -> String {
        pipelineStore.pipeline(withID: event.pipelineId)?.name ?? "Unknown Pipeline"
    }

    private func addEvent() {
        guard let pipeline = pipelineStore.pipelines.first, let id = pipeline.id else { return }
        do {
            let event = try eventStore.createNew(pipelineId: id)
            scheduler.reschedule(events: eventStore.events, pipelineStore: pipelineStore, runner: runner)
            selectedID = event.id
        } catch {
            errorMessage = "\(error)"
        }
    }
}

private struct ScheduleEventRow: View {
    let event: ScheduledEvent
    let pipelineName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.name)
                .font(.headline)
            Text("\(dayLabel) · \(timeLabel) · \(durationLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(pipelineName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .opacity(event.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
    }

    private var dayLabel: String {
        let names = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let active = (0..<7).filter { event.isDayEnabled($0) }.map { names[$0] }
        return active.isEmpty ? "No days" : active.joined(separator: " ")
    }

    private var timeLabel: String {
        let h = event.startTimeSeconds / 3600
        let m = (event.startTimeSeconds % 3600) / 60
        let ampm = h < 12 ? "AM" : "PM"
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", h12, m, ampm)
    }

    private var durationLabel: String {
        let h = event.durationSeconds / 3600
        let m = (event.durationSeconds % 3600) / 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }
}
