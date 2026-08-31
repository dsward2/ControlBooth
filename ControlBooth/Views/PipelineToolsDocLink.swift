import AppKit
import SwiftUI

/// Opens the bundled Pipeline Tools reference (`pipelinetools.html`) in the
/// user's default browser — ControlBooth's equivalent of the "Pipeline Tools
/// documentation" link AntennaHead shows on its Custom Task pages.
enum PipelineToolsDoc {
    static func open() {
        guard let url = Bundle.main.url(forResource: "pipelinetools", withExtension: "html") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Small button that opens the Pipeline Tools reference. Reused by the pipeline
/// list toolbar and the pipeline editor's Stages header.
struct PipelineToolsDocLink: View {
    var body: some View {
        Button {
            PipelineToolsDoc.open()
        } label: {
            Label("Pipeline Tools Documentation", systemImage: "questionmark.circle")
        }
        .help("Open the Pipeline Tools reference in your browser")
    }
}
