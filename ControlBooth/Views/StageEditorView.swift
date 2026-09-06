import AppKit
import PipelineRunner
import SwiftUI

struct StageEditorView: View {
    @Binding var stage: PipelineStage
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @State private var showRawArguments = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let headline {
                            HStack(spacing: 6) {
                                Text(headline)
                                    .font(.headline)
                                    .lineLimit(1)
                                if let issueSummary {
                                    Label(
                                        issueSummary.count == 1 ? "1 issue" : "\(issueSummary.count) issues",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help(issueSummary.text)
                                }
                            }
                        }
                        TextField("Tool path (absolute, or bare name for Contents/Helpers)", text: $stage.path)
                            .font(.body.monospaced())
                            .help(stage.path)
                    }
                    Menu {
                        ForEach(PipelineHelperSpec.Category.allCases, id: \.self) { category in
                            let specs = PipelineHelperCatalog.specs(in: category)
                            if !specs.isEmpty {
                                Section(category.displayName) {
                                    ForEach(specs) { helper in
                                        Button(helper.name) { stage.path = helper.name }
                                    }
                                }
                            }
                        }
                        Section("External tools") {
                            // No catalog spec, so these fall through to the
                            // plain Argument N rows below.
                            ForEach(KnownExternalTools.all, id: \.name) { tool in
                                Button(tool.name) { stage.path = tool.insertionPath }
                            }
                        }
                        Divider()
                        Button("Browse for an external tool…") { chooseToolPath() }
                    } label: {
                        Label("Choose a helper or external tool", systemImage: "square.stack.3d.up.fill")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .help("Insert a built-in Pipeline Helper or a common external tool, or browse the filesystem")
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
                if let spec {
                    StructuredArgumentsView(spec: spec, stage: $stage)
                        .padding(.leading, 16)
                    DisclosureGroup("Raw arguments", isExpanded: $showRawArguments) {
                        rawArgumentEditor
                    }
                    .padding(.leading, 16)
                } else {
                    if let externalTool = KnownExternalTools.match(stage.path) {
                        Label {
                            Text(externalTool.summary)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                    }
                    rawArgumentEditor
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var rawArgumentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
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
    }

    /// The bundled-helper spec for the current tool path, or `nil` for an
    /// external tool / unrecognised name — in which case the plain
    /// `Argument N` rows are shown instead of the structured editor.
    private var spec: PipelineHelperSpec? {
        PipelineHelperCatalog.spec(forToolPath: stage.path)
    }

    private var headline: String? {
        if let spec { return spec.name }
        if let tool = KnownExternalTools.match(stage.path) { return tool.name }
        guard stage.path.contains("/") else { return nil }
        return URL(fileURLWithPath: stage.path).lastPathComponent
    }

    /// Count + tooltip text of the structured stage's current validation
    /// problems, or `nil` for an external tool or a clean stage. Shown next to
    /// the headline so issues are visible even with the argument rows scrolled
    /// out of view.
    private var issueSummary: (count: Int, text: String)? {
        guard let spec else { return nil }
        let issues = HelperArguments(spec: spec, tokens: stage.arguments).allIssues()
        guard !issues.isEmpty else { return nil }
        let text = issues.map { "\($0.flag): \($0.issue.message)" }.joined(separator: "\n")
        return (issues.count, text)
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
