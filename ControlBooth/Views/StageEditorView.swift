import AppKit
import PipelineRunner
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
                    VStack(alignment: .leading, spacing: 2) {
                        if !toolName.isEmpty {
                            Text(toolName)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        TextField("Tool path (absolute, or bare name for Contents/Helpers)", text: $stage.path)
                            .font(.body.monospaced())
                            .help(stage.path)
                    }
                    Button {
                        chooseToolPath()
                    } label: {
                        Label("Choose tool with a file picker", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Choose tool with a file picker")
                    Button {
                        copyStage()
                    } label: {
                        Label("Copy this stage as CLI text", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this stage as CLI text")
                    Button {
                        pasteStage()
                    } label: {
                        Label("Paste a stage's CLI text over this one", systemImage: "doc.on.clipboard")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Paste a stage's CLI text over this one")
                    Button {
                        onMoveUp()
                    } label: {
                        Label("Move stage up", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Move stage up")
                    Button {
                        onMoveDown()
                    } label: {
                        Label("Move stage down", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Move stage down")
                    Button {
                        onDelete()
                    } label: {
                        Label("Delete stage", systemImage: "trash")
                            .labelStyle(.iconOnly)
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
                            Label("Remove argument", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
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

    private var toolName: String {
        guard stage.path.contains("/") else { return "" }
        return URL(fileURLWithPath: stage.path).lastPathComponent
    }

    private func copyStage() {
        let text = CLIStageText.export(CLIStage(path: stage.path, arguments: stage.arguments))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // Pasted text may itself be a whole `|`-joined pipeline (e.g. copied from
    // ControlBooth's own "Copy Pipeline" or from AntennaHead); only the first
    // stage applies here since this button edits a single stage in place.
    private func pasteStage() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let parsed = CLIStageText.importStage(text) else { return }
        stage.path = parsed.path
        stage.arguments = parsed.arguments
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
