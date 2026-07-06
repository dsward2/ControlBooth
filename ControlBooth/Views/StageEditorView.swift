import AppKit
import SwiftUI

struct StageEditorView: View {
    @Binding var stage: PipelineStage
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Tool path (absolute, or bare name for Contents/Helpers)", text: $stage.path)
                        .font(.body.monospaced())
                    Button {
                        chooseToolPath()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose tool with a file picker")
                    Button {
                        onMoveUp()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Move stage up")
                    Button {
                        onMoveDown()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Move stage down")
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete stage")
                }
                ForEach(stage.arguments.indices, id: \.self) { index in
                    HStack {
                        TextField("Argument \(index + 1)", text: argumentBinding(index))
                            .font(.body.monospaced())
                        Button {
                            if stage.arguments.indices.contains(index) {
                                stage.arguments.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove argument")
                    }
                    .padding(.leading, 16)
                }
                Button {
                    stage.arguments.append("")
                } label: {
                    Label("Add Argument", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .padding(.leading, 16)
            }
            .padding(4)
        }
    }

    private func chooseToolPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Tools usually live in directories panels hide (/opt, /usr/local).
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the executable for this stage."
        panel.prompt = "Choose"
        let current = PipelineRunner.resolveToolPath(stage.path)
        if current.contains("/") {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            stage.path = url.path
        }
    }

    // Index-guarded binding: SwiftUI can re-evaluate rows while an argument is
    // being removed, so a plain $stage.arguments[index] subscript could trap.
    private func argumentBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                stage.arguments.indices.contains(index) ? stage.arguments[index] : ""
            },
            set: { newValue in
                if stage.arguments.indices.contains(index) {
                    stage.arguments[index] = newValue
                }
            }
        )
    }
}
