import Foundation
import PipelineRunner

/// A stage's flat `arguments` token list read through a `PipelineHelperSpec`:
/// pulls the value for each catalogued option, reports validation issues, and
/// returns edited copies of the token array (callers assign the result back to
/// `stage.arguments`).
///
/// Pure value type, no SwiftUI — `StructuredArgumentsView` binds to it,
/// `StageEditorView` uses it for the header issue count, and `ControlBoothTests`
/// exercises it directly. The stored model and the cross-app
/// `{"tasks":[…]}` JSON are unchanged; this is only a lens over `[String]`.
///
/// `nonisolated` so the module's default main-actor isolation doesn't make its
/// `Issue: Equatable` conformance unusable from the (nonisolated) test suite.
nonisolated struct HelperArguments {
    let spec: PipelineHelperSpec
    var tokens: [String]

    // MARK: - Reading

    /// The value token following `option`'s flag, or "" when the flag is
    /// absent or immediately followed by another flag.
    func scalarValue(_ option: PipelineHelperOption) -> String {
        guard let i = tokens.firstIndex(where: { matches($0, option) }) else { return "" }
        let next = i + 1 < tokens.count ? tokens[i + 1] : ""
        return isFlagToken(next) ? "" : next
    }

    /// One entry per occurrence of a repeatable option's flag, in order.
    func repeatedValues(_ option: PipelineHelperOption) -> [String] {
        occurrenceFlagIndices(option).map { i in
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            return isFlagToken(next) ? "" : next
        }
    }

    func isFlagPresent(_ option: PipelineHelperOption) -> Bool {
        tokens.contains(option.flag)
    }

    func hasAnyValue(_ option: PipelineHelperOption) -> Bool {
        if case .flag = option.kind { return isFlagPresent(option) }
        if option.isRepeatable {
            return repeatedValues(option).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return !scalarValue(option).isEmpty
    }

    /// Tokens no catalogued option accounts for — typos, or flags added to the
    /// helper since the catalog was written.
    func unrecognizedTokens() -> [String] {
        var consumed = Set<Int>()
        for option in spec.options {
            var i = 0
            while i < tokens.count {
                if matches(tokens[i], option) {
                    consumed.insert(i)
                    if case .flag = option.kind {
                        i += 1
                    } else if i + 1 < tokens.count && !isFlagToken(tokens[i + 1]) {
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
        return tokens.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
    }

    // MARK: - Validation

    enum Issue: Equatable {
        case missingRequired
        case notInteger
        case notNumber
        case outOfRange(String)
        case notAllowed([String])

        var message: String {
            switch self {
            case .missingRequired: return "Required."
            case .notInteger: return "Whole number."
            case .notNumber: return "Number."
            case .outOfRange(let range): return "Range \(range)."
            case .notAllowed(let cases): return "One of: \(cases.joined(separator: ", "))."
            }
        }
    }

    /// The issue with `option`'s current value, or `nil` when it's acceptable.
    /// Repeatable options report only `missingRequired` here; per-row range /
    /// enum problems come from `rowIssue(_:value:)`.
    func issue(_ option: PipelineHelperOption) -> Issue? {
        if option.isRepeatable {
            return option.isRequired && !hasAnyValue(option) ? .missingRequired : nil
        }
        let value = scalarValue(option).trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            return option.isRequired ? .missingRequired : nil
        }
        return valueIssue(value, kind: option.kind)
    }

    /// Range / enum check for one repeated-row value (empty rows are ignored —
    /// the group-level `missingRequired` covers "no rows at all").
    func rowIssue(_ option: PipelineHelperOption, value: String) -> Issue? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return valueIssue(trimmed, kind: option.kind)
    }

    private func valueIssue(_ value: String, kind: PipelineHelperOption.Kind) -> Issue? {
        switch kind {
        case .flag, .string, .path:
            return nil
        case .enumeration(let cases):
            return cases.contains(value) ? nil : .notAllowed(cases)
        case .int(let range):
            guard let n = Int(value) else { return .notInteger }
            if let range, !range.contains(n) {
                return .outOfRange("\(range.lowerBound)–\(range.upperBound)")
            }
            return nil
        case .double(let range):
            guard let d = Double(value) else { return .notNumber }
            if let range, !range.contains(d) {
                return .outOfRange("\(range.lowerBound)–\(range.upperBound)")
            }
            return nil
        }
    }

    /// Every current issue across the spec, as `(flag, issue)` — for a summary
    /// count / tooltip in the stage header.
    func allIssues() -> [(flag: String, issue: Issue)] {
        var result: [(flag: String, issue: Issue)] = []
        for option in spec.options {
            if let issue = issue(option) {
                result.append((option.flag, issue))
            }
            if option.isRepeatable {
                for value in repeatedValues(option) {
                    if let issue = rowIssue(option, value: value) {
                        result.append((option.flag, issue))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Editing (returns a new token array; caller assigns it back)

    func settingScalar(_ option: PipelineHelperOption, to newValue: String) -> [String] {
        var args = tokens
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
        return args
    }

    func togglingFlag(_ option: PipelineHelperOption, on: Bool) -> [String] {
        var args = tokens
        args.removeAll { $0 == option.flag }
        if on { args.append(option.flag) }
        return args
    }

    func appendingRepeated(_ option: PipelineHelperOption) -> [String] {
        tokens + [option.flag, ""]
    }

    func settingRepeated(_ option: PipelineHelperOption, occurrence: Int, to newValue: String) -> [String] {
        var args = tokens
        let indices = occurrenceFlagIndices(option)
        guard indices.indices.contains(occurrence) else { return args }
        let flagIndex = indices[occurrence]
        args[flagIndex] = option.flag
        let hasValue = flagIndex + 1 < args.count && !isFlagToken(args[flagIndex + 1])
        if hasValue { args[flagIndex + 1] = newValue } else { args.insert(newValue, at: flagIndex + 1) }
        return args
    }

    func removingRepeated(_ option: PipelineHelperOption, occurrence: Int) -> [String] {
        var args = tokens
        let indices = occurrenceFlagIndices(option)
        guard indices.indices.contains(occurrence) else { return args }
        let flagIndex = indices[occurrence]
        let hasValue = flagIndex + 1 < args.count && !isFlagToken(args[flagIndex + 1])
        args.removeSubrange(flagIndex...(hasValue ? flagIndex + 1 : flagIndex))
        return args
    }

    // MARK: - Token internals

    /// A `-x` token that introduces an option, as opposed to a negative number
    /// value like `-45` (`--azimuth`, `--elevation`, …).
    private func isFlagToken(_ token: String) -> Bool {
        guard token.hasPrefix("-") else { return false }
        if token.hasPrefix("--") { return true }
        return Double(token) == nil
    }

    private func matches(_ token: String, _ option: PipelineHelperOption) -> Bool {
        token == option.flag || option.aliases.contains(token)
    }

    /// Index of each occurrence's *flag* token in `tokens`.
    private func occurrenceFlagIndices(_ option: PipelineHelperOption) -> [Int] {
        var indices: [Int] = []
        var i = 0
        while i < tokens.count {
            if matches(tokens[i], option) {
                indices.append(i)
                i += (i + 1 < tokens.count && !isFlagToken(tokens[i + 1])) ? 2 : 1
            } else {
                i += 1
            }
        }
        return indices
    }
}
