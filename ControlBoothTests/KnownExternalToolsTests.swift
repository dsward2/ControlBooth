import Testing
import Foundation
@testable import ControlBooth
import PipelineRunner

/// The tool-picker menus in `StageEditorView` / `PipelineEditorView` list
/// `KnownExternalTools.all` in an "External tools" section. Picking one sets a
/// stage's `path` to its `insertionPath`, and the editor must then show the
/// generic `Argument N` rows — i.e. these must never resolve to a
/// `PipelineHelperCatalog` spec.
struct KnownExternalToolsTests {

    @Test func everyEntryIsWellFormed() {
        for tool in KnownExternalTools.all {
            #expect(!tool.name.isEmpty)
            #expect(!tool.summary.isEmpty)
            #expect(!tool.insertionPath.isEmpty)
        }
    }

    @Test func noExternalToolShadowsACatalogHelper() {
        let catalogNames = Set(PipelineHelperCatalog.all.map(\.name))
        let externalNames = Set(KnownExternalTools.all.map(\.name))
        #expect(catalogNames.isDisjoint(with: externalNames),
                "an external tool shares a name with a bundled helper — the structured editor would claim it")
    }

    @Test func insertionPathAlwaysFallsThroughToTheGenericEditor() {
        for tool in KnownExternalTools.all {
            #expect(PipelineHelperCatalog.spec(forToolPath: tool.insertionPath) == nil,
                    "\(tool.name) inserts \(tool.insertionPath), which the structured editor would claim")
        }
    }

    @Test func hintStillResolvesAfterInsertion() {
        // StageEditorView shows `KnownExternalTools.match(stage.path)?.summary`
        // as a hint; it must still find the tool from whatever the menu put in
        // `path` (bare name or absolute path).
        for tool in KnownExternalTools.all {
            #expect(KnownExternalTools.match(tool.insertionPath)?.name == tool.name)
        }
    }

    @Test func systemToolsInsertAnAbsolutePath() throws {
        // A bare "nc" would wrongly resolve against Contents/Helpers; it must
        // go in as /usr/bin/nc. Bundled tools stay bare so they resolve there.
        let nc = try #require(KnownExternalTools.all.first { $0.name == "nc" })
        #expect(nc.insertionPath == "/usr/bin/nc")

        for bundled in ["sox", "stereodemux", "rtl_fm_localradio", "ffmpeg"] {
            let tool = KnownExternalTools.all.first { $0.name == bundled }
            #expect(tool?.insertionPath == bundled, "\(bundled) should insert as a bare name")
        }
    }
}
