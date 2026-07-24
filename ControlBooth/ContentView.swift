import SwiftUI

struct ContentView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(ScheduledEventStore.self) private var eventStore
    @Environment(AirPlaySettingsStore.self) private var airPlaySettingsStore
    @State private var selectedPipelineID: Int64?
    @State private var selectedEventID: Int64?

    var body: some View {
        TabView {
            NavigationSplitView {
                PipelineListView(selectedID: $selectedPipelineID)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                if let id = selectedPipelineID, let pipeline = store.pipeline(withID: id) {
                    PipelineEditorView(pipeline: pipeline)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "No Pipeline Selected",
                        systemImage: "waveform.path",
                        description: Text("Select a pipeline in the sidebar, or add one with the + button.")
                    )
                }
            }
            .tabItem { Label("Pipelines", systemImage: "waveform.path") }

            NavigationSplitView {
                ScheduleListView(selectedID: $selectedEventID)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                if let id = selectedEventID, let event = eventStore.event(withID: id) {
                    ScheduleEditorView(event: event)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "No Event Selected",
                        systemImage: "calendar.clock",
                        description: Text("Select a scheduled event, or add one with the + button.")
                    )
                }
            }
            .tabItem { Label("Schedule", systemImage: "calendar.clock") }

            AirPlaySettingsView(settings: airPlaySettingsStore.settings)
                .id(airPlaySettingsStore.settings)
                .tabItem { Label("AirPlay", systemImage: "airplayaudio") }
        }
        .frame(minWidth: 880, minHeight: 560)
    }
}

#Preview {
    ContentView()
        .environment(PipelineStore())
        .environment(ScheduledEventStore())
        .environment(PipelineRunner())
        .environment(Scheduler())
}
