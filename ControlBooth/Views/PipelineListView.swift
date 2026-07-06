import SwiftUI

struct PipelineListView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(PipelineRunner.self) private var runner
    @Binding var selectedID: Int64?
    @State private var errorMessage: String?

    var body: some View {
        List(selection: $selectedID) {
            ForEach(store.pipelines) { pipeline in
                PipelineRowView(pipeline: pipeline, errorMessage: $errorMessage)
                    .tag(pipeline.id ?? -1)
            }
        }
        .navigationTitle("ControlBooth")
        .toolbar {
            ToolbarItem {
                Button {
                    addPipeline()
                } label: {
                    Label("Add Pipeline", systemImage: "plus")
                }
                .help("Add a new pipeline")
            }
        }
        .alert("Pipeline Error", isPresented: errorPresented) {
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

    private func addPipeline() {
        do {
            let newPipeline = try store.createNew()
            selectedID = newPipeline.id
        } catch {
            errorMessage = "\(error)"
        }
    }
}

struct PipelineRowView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(PipelineRunner.self) private var runner
    let pipeline: Pipeline
    @Binding var errorMessage: String?

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(pipeline.name)
                .lineLimit(1)
            Spacer()
            Button {
                toggleRunning()
            } label: {
                Image(systemName: runner.isRunning(pipeline) ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(runner.isRunning(pipeline) ? "Stop pipeline" : "Start pipeline")
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                deletePipeline()
            }
        }
    }

    private var statusColor: Color {
        if runner.isRunning(pipeline) {
            return .green
        }
        if runner.lastFailure(for: pipeline) != nil {
            return .red
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private func toggleRunning() {
        if runner.isRunning(pipeline) {
            runner.stop(pipeline)
        } else {
            do {
                try runner.start(pipeline)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    private func deletePipeline() {
        runner.stop(pipeline)
        do {
            try store.delete(pipeline)
        } catch {
            errorMessage = "\(error)"
        }
    }
}
