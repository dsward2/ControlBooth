import Testing
@testable import ControlBooth
import PipelineRunner

struct HelperArgumentsTests {

    private func spec(_ name: String) -> PipelineHelperSpec {
        PipelineHelperCatalog.spec(forToolPath: name)!
    }

    private func option(_ spec: PipelineHelperSpec, _ flag: String) -> PipelineHelperOption {
        spec.options.first { $0.flag == flag }!
    }

    // MARK: Reading

    @Test func scalarValueReadsTokenAfterFlag() {
        let s = spec("PCMUDPReceiver")
        let a = HelperArguments(spec: s, tokens: ["--port", "6030", "--exit-with-parent"])
        #expect(a.scalarValue(option(s, "--port")) == "6030")
        #expect(a.scalarValue(option(s, "--bind")) == "")
        #expect(a.isFlagPresent(option(s, "--exit-with-parent")))
    }

    @Test func scalarValueIsEmptyWhenFlagIsFollowedByAnotherFlag() {
        let s = spec("PCMUDPReceiver")
        let a = HelperArguments(spec: s, tokens: ["--port", "--exit-with-parent"])
        #expect(a.scalarValue(option(s, "--port")) == "")
    }

    @Test func scalarValueResolvesAnAlias() {
        let s = spec("PCMUDPReceiver")
        let a = HelperArguments(spec: s, tokens: ["-p", "6030"])
        #expect(a.scalarValue(option(s, "--port")) == "6030")
    }

    @Test func negativeNumberIsAValueNotAFlag() {
        let s = spec("PCMBinauralPanner")
        let a = HelperArguments(spec: s, tokens: ["--azimuth", "-45"])
        #expect(a.scalarValue(option(s, "--azimuth")) == "-45")
    }

    // MARK: Editing

    @Test func settingScalarInsertsUpdatesInPlaceAndRemovesOnEmpty() {
        let s = spec("PCMUDPReceiver")
        let port = option(s, "--port")

        var tokens = HelperArguments(spec: s, tokens: []).settingScalar(port, to: "6030")
        #expect(tokens == ["--port", "6030"])

        tokens = HelperArguments(spec: s, tokens: tokens).settingScalar(port, to: "6031")
        #expect(tokens == ["--port", "6031"])

        tokens = HelperArguments(spec: s, tokens: tokens).settingScalar(port, to: "")
        #expect(tokens == [])
    }

    @Test func settingScalarNormalisesAnAliasToTheCanonicalFlag() {
        let s = spec("PCMUDPReceiver")
        let tokens = HelperArguments(spec: s, tokens: ["-p", "6030"])
            .settingScalar(option(s, "--port"), to: "6031")
        #expect(tokens == ["--port", "6031"])
    }

    @Test func togglingFlagAddsAndRemoves() {
        let s = spec("PCMSpeechSynth")
        let ssml = option(s, "--ssml")

        var tokens = HelperArguments(spec: s, tokens: ["--repeat"]).togglingFlag(ssml, on: true)
        #expect(tokens.contains("--ssml"))

        tokens = HelperArguments(spec: s, tokens: tokens).togglingFlag(ssml, on: false)
        #expect(!tokens.contains("--ssml"))
        #expect(tokens.contains("--repeat"))
    }

    @Test func repeatableRoundTrip() {
        let s = spec("PCMFilePlayer")
        let file = option(s, "--file")

        var tokens = HelperArguments(spec: s, tokens: []).appendingRepeated(file)
        tokens = HelperArguments(spec: s, tokens: tokens).settingRepeated(file, occurrence: 0, to: "/a.m4a")
        tokens = HelperArguments(spec: s, tokens: tokens).appendingRepeated(file)
        tokens = HelperArguments(spec: s, tokens: tokens).settingRepeated(file, occurrence: 1, to: "/b.m4a")
        #expect(tokens == ["--file", "/a.m4a", "--file", "/b.m4a"])

        #expect(HelperArguments(spec: s, tokens: tokens).repeatedValues(file) == ["/a.m4a", "/b.m4a"])

        tokens = HelperArguments(spec: s, tokens: tokens).removingRepeated(file, occurrence: 0)
        #expect(tokens == ["--file", "/b.m4a"])
    }

    // MARK: Validation

    @Test func requiredEmptyOptionIsFlagged() {
        let s = spec("PCMUDPReceiver")
        let a = HelperArguments(spec: s, tokens: [])
        #expect(a.issue(option(s, "--port")) == .missingRequired)
        #expect(a.issue(option(s, "--bind")) == nil) // optional
    }

    @Test func integerRangeIsChecked() {
        let s = spec("PCMUDPReceiver")
        let port = option(s, "--port")
        #expect(HelperArguments(spec: s, tokens: ["--port", "70000"]).issue(port) == .outOfRange("1–65535"))
        #expect(HelperArguments(spec: s, tokens: ["--port", "abc"]).issue(port) == .notInteger)
        #expect(HelperArguments(spec: s, tokens: ["--port", "6030"]).issue(port) == nil)
    }

    @Test func doubleRangeIsChecked() {
        let s = spec("PCMBinauralPanner")
        let elevation = option(s, "--elevation")
        #expect(HelperArguments(spec: s, tokens: ["--elevation", "120"]).issue(elevation) == .outOfRange("-90.0–90.0"))
        #expect(HelperArguments(spec: s, tokens: ["--elevation", "x"]).issue(elevation) == .notNumber)
        #expect(HelperArguments(spec: s, tokens: ["--elevation", "-45"]).issue(elevation) == nil)
    }

    @Test func enumerationValueIsChecked() {
        let s = spec("PCMPrefix")
        let during = option(s, "--during-prefix")
        if case .notAllowed(let cases)? = HelperArguments(spec: s, tokens: ["--during-prefix", "nope"]).issue(during) {
            #expect(cases == ["drop", "hold"])
        } else {
            Issue.record("expected .notAllowed")
        }
        #expect(HelperArguments(spec: s, tokens: ["--during-prefix", "hold"]).issue(during) == nil)
    }

    @Test func allIssuesAggregatesAcrossOptions() {
        let s = spec("PCMUDPReceiver")
        // --port required and out of range counts once (value present ⇒ range check)
        let issues = HelperArguments(spec: s, tokens: ["--port", "70000"]).allIssues()
        #expect(issues.count == 1)
        #expect(issues.first?.flag == "--port")
    }

    @Test func unrecognizedTokensSurfaceTypos() {
        let s = spec("PCMSpeechSynth")
        let a = HelperArguments(spec: s, tokens: ["--rate", "22050", "--rat", "48000", "--repeat"])
        #expect(a.unrecognizedTokens() == ["--rat", "48000"])
    }
}
