import PipelineRunner
import SwiftUI

/// Argument editor for a stage whose tool is a recognised Pipeline Helper.
/// Renders one labelled control per catalogued option — bound to the stage's
/// flat `arguments` array via `HelperArguments` — with inline validation, plus
/// a note listing anything the catalog doesn't model (still editable in the
/// "Raw arguments" disclosure).
///
/// External tools (nrsc5, rtl_fm, …) never reach this view: `StageEditorView`
/// only shows it when `PipelineHelperCatalog.spec(forToolPath:)` matches, and
/// falls back to the plain `Argument N` rows otherwise.
struct StructuredArgumentsView: View {
    let spec: PipelineHelperSpec
    @Binding var stage: PipelineStage

    private var args: HelperArguments {
        HelperArguments(spec: spec, tokens: stage.arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if spec.options.isEmpty {
                Text("This helper takes no options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(spec.options, id: \.flag) { option in
                    row(option)
                }
            }

            let leftovers = args.unrecognizedTokens()
            if !leftovers.isEmpty {
                Divider()
                Label {
                    Text("Not recognised for \(spec.name): "
                         + leftovers.map { "`\($0)`" }.joined(separator: " "))
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ option: PipelineHelperOption) -> some View {
        let issue = args.issue(option)
        GridRow {
            optionLabel(option, issue: issue)
                .gridColumnAlignment(.trailing)

            switch option.kind {
            case .flag:
                Toggle(isOn: flagBinding(option)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .enumeration(let cases):
                fieldColumn(issue: issue) {
                    Picker("", selection: scalarBinding(option)) {
                        Text(defaultTag(option)).tag("")
                        ForEach(cases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                }

            default:
                if option.isRepeatable {
                    repeatableRows(option, groupIssue: issue)
                } else {
                    fieldColumn(issue: issue) {
                        TextField("", text: scalarBinding(option), prompt: Text(placeholderText(option)))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(fieldBorder(issue))
                    }
                }
            }
        }
    }

    /// A field plus, when present, a small red caption underneath it.
    @ViewBuilder
    private func fieldColumn<Content: View>(
        issue: HelperArguments.Issue?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
            if let issue {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldBorder(_ issue: HelperArguments.Issue?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.red.opacity(0.7), lineWidth: issue == nil ? 0 : 1)
    }

    @ViewBuilder
    private func repeatableRows(_ option: PipelineHelperOption, groupIssue: HelperArguments.Issue?) -> some View {
        let values = args.repeatedValues(option)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                let rowIssue = args.rowIssue(option, value: values.indices.contains(index) ? values[index] : "")
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("", text: repeatedBinding(option, occurrence: index),
                                  prompt: Text(placeholderText(option)))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .font(.body.monospaced())
                            .overlay(fieldBorder(rowIssue))
                        Button {
                            stage.arguments = args.removingRepeated(option, occurrence: index)
                        } label: {
                            Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this \(option.flag)")
                    }
                    if let rowIssue {
                        Text(rowIssue.message).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            if let groupIssue {
                Text(groupIssue.message).font(.caption2).foregroundStyle(.red)
            }
            Button {
                stage.arguments = args.appendingRepeated(option)
            } label: {
                Label("Add \(option.flag)", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionLabel(_ option: PipelineHelperOption, issue: HelperArguments.Issue?) -> some View {
        HStack(spacing: 4) {
            Text(option.flag).font(.body.monospaced())
            if let issue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help(issue.message)
            }
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .help(helpText(option))
    }

    // MARK: - Help text

    private func helpText(_ option: PipelineHelperOption) -> String {
        var text = option.summary
        if let def = option.defaultValue {
            text += "  (default: \(def))"
        } else if option.isRequired {
            text += "  (required)"
        }
        if case .int(let range?) = option.kind {
            text += "  [\(range.lowerBound)–\(range.upperBound)]"
        }
        if case .double(let range?) = option.kind {
            text += "  [\(range.lowerBound)–\(range.upperBound)]"
        }
        return text
    }

    private func defaultTag(_ option: PipelineHelperOption) -> String {
        option.defaultValue.map { "default (\($0))" } ?? "default"
    }

    private func placeholderText(_ option: PipelineHelperOption) -> String {
        if let def = option.defaultValue { return def }
        return option.placeholder ?? ""
    }

    // MARK: - Bindings

    private func scalarBinding(_ option: PipelineHelperOption) -> Binding<String> {
        Binding(
            get: { args.scalarValue(option) },
            set: { stage.arguments = args.settingScalar(option, to: $0) }
        )
    }

    private func flagBinding(_ option: PipelineHelperOption) -> Binding<Bool> {
        Binding(
            get: { args.isFlagPresent(option) },
            set: { stage.arguments = args.togglingFlag(option, on: $0) }
        )
    }

    private func repeatedBinding(_ option: PipelineHelperOption, occurrence: Int) -> Binding<String> {
        Binding(
            get: {
                let values = args.repeatedValues(option)
                return values.indices.contains(occurrence) ? values[occurrence] : ""
            },
            set: { stage.arguments = args.settingRepeated(option, occurrence: occurrence, to: $0) }
        )
    }
}
