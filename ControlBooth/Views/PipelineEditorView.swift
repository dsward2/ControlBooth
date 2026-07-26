import AppKit
import PipelineRunner
import SwiftUI

struct PipelineEditorView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(PipelineRunner.self) private var runner

    let pipeline: Pipeline
    @State private var name: String
    @State private var destinationHost: String
    @State private var destinationPort: Int
    @State private var stages: [PipelineStage]
    @State private var errorMessage: String?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        _name = State(initialValue: pipeline.name)
        _destinationHost = State(initialValue: pipeline.destinationHost)
        _destinationPort = State(initialValue: pipeline.destinationPort)
        _stages = State(initialValue: pipeline.stages)
    }

    var body: some View {
        Form {
            Section("Pipeline") {
                TextField("Name", text: $name)
                TextField("Destination Host", text: $destinationHost)
                TextField("Destination Port", value: $destinationPort, format: .number.grouping(.never))
            }
            Section {
                ForEach($stages) { $stage in
                    StageEditorView(
                        stage: $stage,
                        onMoveUp: { move(stage, by: -1) },
                        onMoveDown: { move(stage, by: 1) },
                        onDelete: { remove(stage) }
                    )
                }
                HStack {
                    Button {
                        stages.append(PipelineStage())
                    } label: {
                        Label("Add Stage", systemImage: "plus")
                    }
                    Button {
                        copyPipeline()
                    } label: {
                        Label("Copy Pipeline", systemImage: "doc.on.doc")
                    }
                    .disabled(stages.isEmpty)
                    .help("Copy all stages as `|`-joined CLI text")
                    Button {
                        pastePipeline()
                    } label: {
                        Label("Paste Pipeline", systemImage: "doc.on.clipboard")
                    }
                    .help("Replace all stages with pasted CLI text")
                }
            } header: {
                Text("Stages")
            } footer: {
                Text("Audio flows stage → stage via stdin/stdout. `PCMUDPSender --host \(destinationHost) --port \(String(destinationPort)) --exit-with-parent` is appended automatically as the final stage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                PipelineStatusView(pipeline: pipeline)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pipeline.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Save") {
                    do {
                        try persist()
                    } catch {
                        errorMessage = "\(error)"
                    }
                }
                if runner.isRunning(pipeline) {
                    Button {
                        runner.stop(pipeline)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop pipeline")
                } else {
                    Button {
                        saveAndStart()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Save and start pipeline")
                }
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

    @discardableResult
    private func persist() throws -> Pipeline {
        var updated = pipeline
        updated.name = name
        updated.destinationHost = destinationHost
        updated.destinationPort = destinationPort
        updated.stages = stages
        return try store.save(updated)
    }

    private func saveAndStart() {
        do {
            let saved = try persist()
            try runner.start(saved)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func copyPipeline() {
        let text = CLIStageText.export(pipeline: stages.map { CLIStage(path: $0.path, arguments: $0.arguments) })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pastePipeline() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let parsed = CLIStageText.importPipeline(text)
        guard !parsed.isEmpty else { return }
        stages = parsed.map { PipelineStage(path: $0.path, arguments: $0.arguments) }
    }

    private func remove(_ stage: PipelineStage) {
        stages.removeAll { $0.id == stage.id }
    }

    private func move(_ stage: PipelineStage, by offset: Int) {
        guard let index = stages.firstIndex(where: { $0.id == stage.id }) else { return }
        let target = index + offset
        guard stages.indices.contains(target) else { return }
        stages.swapAt(index, target)
    }
}
