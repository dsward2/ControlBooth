import SwiftUI

struct ContentView: View {
    @Environment(PipelineStore.self) private var store
    @State private var selectedID: Int64?

    var body: some View {
        NavigationSplitView {
            PipelineListView(selectedID: $selectedID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let id = selectedID, let pipeline = store.pipeline(withID: id) {
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
        .frame(minWidth: 880, minHeight: 560)
    }
}

#Preview {
    ContentView()
        .environment(PipelineStore())
        .environment(PipelineRunner())
}
