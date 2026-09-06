import Testing
import Foundation
@testable import ControlBooth
import PipelineRunner

/// Keeps the bundled `pipelinetools.html` reference in step with the catalog it
/// documents. `PipelineHelperCatalog` is itself checked against each helper's
/// `main.swift` in PipelineHelpers' own tests, so a green run here means
/// source → catalog → reference doc all agree.
struct PipelineToolsDocTests {

    private func docText() throws -> String {
        let url = try #require(PipelineToolsDoc.bundledURL,
                               "pipelinetools.html is not in the app bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyHelperHasAHeadingAndAllItsFlagsDocumented() throws {
        let doc = try docText()
        for spec in PipelineHelperCatalog.all {
            #expect(doc.contains("<h3>\(spec.name) "),
                    "pipelinetools.html has no <h3> section for \(spec.name)")
            for option in spec.options {
                #expect(doc.contains("<code>\(option.flag)"),
                        "pipelinetools.html never documents \(spec.name)'s \(option.flag)")
            }
        }
    }

    @Test func knownExternalToolsWithADocSectionHaveAHeading() throws {
        let doc = try docText()
        for tool in KnownExternalTools.all where tool.hasDocSection {
            #expect(doc.contains("<h3>\(tool.name) "),
                    "pipelinetools.html has no <h3> section for \(tool.name)")
        }
    }
}
