import PipelineRunner
import SwiftUI

/// Argument editor for a stage whose tool is a recognised Pipeline Helper.
/// Renders one labelled control per catalogued option — bound directly to the
/// stage's flat `arguments` array — plus a note listing anything the catalog
/// doesn't model (still editable in the "Raw arguments" disclosure).
///
/// External tools (nrsc5, rtl_fm, …) never reach this view: `StageEditorView`
/// only shows it when `PipelineHelperCatalog.spec(forToolPath:)` matches, and
/// falls back to the plain `Argument N` rows otherwise.
struct StructuredArgumentsView: View {
    let spec: PipelineHelperSpec
    @Binding var stage: PipelineStage

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

            let leftovers = unrecognizedTokens()
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
        GridRow {
            optionLabel(option)
                .gridColumnAlignment(.trailing)

            switch option.kind {
            case .flag:
                Toggle(isOn: flagBinding(option)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .enumeration(let cases):
                Picker("", selection: scalarBinding(option)) {
                    Text(defaultTag(option)).tag("")
                    ForEach(cases, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)

            default:
                if option.isRepeatable {
                    repeatableRows(option)
                } else {
                    TextField("", text: scalarBinding(option), prompt: Text(placeholderText(option)))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func repeatableRows(_ option: PipelineHelperOption) -> some View {
        let values = repeatedValues(option)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField("", text: repeatedBinding(option, occurrence: index),
                              prompt: Text(placeholderText(option)))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .font(.body.monospaced())
                    Button {
                        removeOccurrence(option, at: index)
                    } label: {
                        Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this \(option.flag)")
                }
            }
            Button {
                stage.arguments.append(contentsOf: [option.flag, ""])
            } label: {
                Label("Add \(option.flag)", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionLabel(_ option: PipelineHelperOption) -> some View {
        HStack(spacing: 4) {
            Text(option.flag).font(.body.monospaced())
            if isMissingRequired(option) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("\(option.flag) is required")
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

    private func isMissingRequired(_ option: PipelineHelperOption) -> Bool {
        option.isRequired && !hasAnyValue(option)
    }

    private func hasAnyValue(_ option: PipelineHelperOption) -> Bool {
        if case .flag = option.kind {
            return stage.arguments.contains(option.flag)
        }
        if option.isRepeatable {
            return repeatedValues(option).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return !scalarValue(option).isEmpty
    }

    // MARK: - Token helpers

    /// A `-x` token that introduces an option, as opposed to a negative
    /// number value like `-45` (used by `--azimuth`, `--elevation`, …).
    private func isFlagToken(_ token: String) -> Bool {
        guard token.hasPrefix("-") else { return false }
        if token.hasPrefix("--") { return true }
        return Double(token) == nil
    }

    private func matches(_ token: String, _ option: PipelineHelperOption) -> Bool {
        token == option.flag || option.aliases.contains(token)
    }

    // MARK: - Scalar / flag bindings

    private func scalarValue(_ option: PipelineHelperOption) -> String {
        let args = stage.arguments
        guard let i = args.firstIndex(where: { matches($0, option) }) else { return "" }
        let next = i + 1 < args.count ? args[i + 1] : ""
        return isFlagToken(next) ? "" : next
    }

    private func scalarBinding(_ option: PipelineHelperOption) -> Binding<String> {
        Binding(
            get: { scalarValue(option) },
            set: { setScalar(option, $0) }
        )
    }

    private func setScalar(_ option: PipelineHelperOption, _ newValue: String) {
        var args = stage.arguments
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = args.firstIndex(where: { matches($0, option) }) {
            let hasValue = i + 1 < args.count && !isFlagToken(args[i + 1])
            if trimmed.isEmpty {
                args.removeSubrange(hasValue ? i...(i + 1) : i...i)
            } else {
                args[i] = option.flag // normalise an alias to the canonical flag
                if hasValue { args[i + 1] = newValue } else { args.insert(newValue, at: i + 1) }
            }
        } else if !trimmed.isEmpty {
            args.append(contentsOf: [option.flag, newValue])
        }
        stage.arguments = args
    }

    private func flagBinding(_ option: PipelineHelperOption) -> Binding<Bool> {
        Binding(
            get: { stage.arguments.contains(option.flag) },
            set: { isOn in
                var args = stage.arguments
                args.removeAll { $0 == option.flag }
                if isOn { args.append(option.flag) }
                stage.arguments = args
            }
        )
    }

    // MARK: - Repeatable bindings

    /// Byte offsets of each occurrence's *flag* token in `stage.arguments`.
    private func occurrenceFlagIndices(_ option: PipelineHelperOption) -> [Int] {
        let args = stage.arguments
        var indices: [Int] = []
        var i = 0
        while i < args.count {
            if matches(args[i], option) {
                indices.append(i)
                i += (i + 1 < args.count && !isFlagToken(args[i + 1])) ? 2 : 1
            } else {
                i += 1
            }
        }
        return indices
    }

    private func repeatedValues(_ option: PipelineHelperOption) -> [String] {
        let args = stage.arguments
        return occurrenceFlagIndices(option).map { i in
            let next = i + 1 < args.count ? args[i + 1] : ""
            return isFlagToken(next) ? "" : next
        }
    }

    private func repeatedBinding(_ option: PipelineHelperOption, occurrence: Int) -> Binding<String> {
        Binding(
            get: {
                let values = repeatedValues(option)
                return values.indices.contains(occurrence) ? values[occurrence] : ""
            },
            set: { newValue in
                var args = stage.arguments
                let indices = occurrenceFlagIndices(option)
                guard indices.indices.contains(occurrence) else { return }
                let flagIndex = indices[occurrence]
                args[flagIndex] = option.flag
                let hasValue = flagIndex + 1 < args.count && !isFlagToken(args[flagIndex + 1])
                if hasValue { args[flagIndex + 1] = newValue } else { args.insert(newValue, at: flagIndex + 1) }
                stage.arguments = args
            }
        )
    }

    private func removeOccurrence(_ option: PipelineHelperOption, at occurrence: Int) {
        var args = stage.arguments
        let indices = occurrenceFlagIndices(option)
        guard indices.indices.contains(occurrence) else { return }
        let flagIndex = indices[occurrence]
        let hasValue = flagIndex + 1 < args.count && !isFlagToken(args[flagIndex + 1])
        args.removeSubrange(flagIndex...(hasValue ? flagIndex + 1 : flagIndex))
        stage.arguments = args
    }

    // MARK: - Leftovers

    /// Tokens in `stage.arguments` that no catalogued option accounts for —
    /// typos, or options added to the helper since the catalog was written.
    private func unrecognizedTokens() -> [String] {
        let args = stage.arguments
        var consumed = Set<Int>()
        for option in spec.options {
            var i = 0
            while i < args.count {
                if matches(args[i], option) {
                    consumed.insert(i)
                    if case .flag = option.kind {
                        i += 1
                    } else if i + 1 < args.count && !isFlagToken(args[i + 1]) {
                        consumed.insert(i + 1)
                        i += 2
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }
        return args.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
    }
}
