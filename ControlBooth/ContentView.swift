import SwiftUI

struct ContentView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(ScheduledEventStore.self) private var eventStore
    @Environment(AirPlaySettingsStore.self) private var airPlaySettingsStore
    @State private var selectedPipelineID: Int64?
    @State private var selectedEventID: Int64?

    private enum MainTab: String, CaseIterable, Identifiable {
        case pipelines = "Pipelines"
        case schedule = "Recording Schedule"
        case airPlay = "AirPlay Receiver"
        case dsdNeo = "dsd-neo Scanner"
        case radio = "AntennaHead Radio"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .pipelines: return "waveform.path"
            case .schedule: return "calendar.clock"
            case .airPlay: return "airplayaudio"
            case .dsdNeo: return "antenna.radiowaves.left.and.right"
            case .radio: return "radio"
            }
        }
    }

    @State private var selectedTab: MainTab = .pipelines
    /// Tabs shown at least once. Like the system TabView, a tab's view is
    /// built on first visit and then kept alive (so the scanner's terminal,
    /// editors' unsaved text, etc. survive switching away).
    @State private var visitedTabs: Set<MainTab> = [.pipelines]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ZStack {
                ForEach(MainTab.allCases) { tab in
                    if visitedTabs.contains(tab) {
                        content(for: tab)
                            .opacity(tab == selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == selectedTab)
                            .disabled(tab != selectedTab)
                            .accessibilityHidden(tab != selectedTab)
                    }
                }
            }
        }
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
        .frame(minWidth: 880, minHeight: 560)
    }

    /// The tab buttons. Centred when they fit; in a horizontal scroller (with
    /// the selected tab kept in view) when the window is too narrow for them,
    /// instead of being clipped away as the system tab bar was.
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    tabButtons
                }
                .onChange(of: selectedTab) { _, tab in
                    withAnimation { proxy.scrollTo(tab, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var tabButtons: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tab == selectedTab ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .id(tab)
                .accessibilityAddTraits(tab == selectedTab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func content(for tab: MainTab) -> some View {
        switch tab {
        case .pipelines:
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
        case .schedule:
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
        case .airPlay:
            AirPlaySettingsView(settings: airPlaySettingsStore.settings)
                .id(airPlaySettingsStore.settings)
        case .dsdNeo:
            DsdNeoScannerView()
        case .radio:
            AntennaHeadRadioView()
        }
    }
}

#Preview {
    ContentView()
        .environment(PipelineStore())
        .environment(ScheduledEventStore())
        .environment(PipelineRunner())
        .environment(Scheduler())
}
