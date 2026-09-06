import Foundation

/// External tools ControlBooth pipelines commonly reach for — some vendored in
/// `Contents/Helpers` (sox, stereodemux, rtl_fm_localradio, ffmpeg), some
/// system or user-installed (nc, nrsc5). None has a `PipelineHelperCatalog`
/// spec, so the stage editor gives them the plain `Argument N` rows plus the
/// one-line `summary` as a hint. Also drives the "External tools" section of
/// the tool-picker menus in `StageEditorView` / `PipelineEditorView`.
nonisolated struct KnownExternalTool: Equatable {
    let name: String
    let summary: String
    /// Whether `pipelinetools.html` carries a dedicated `<h3>` section for it
    /// (asserted by `PipelineToolsDocTests`).
    let hasDocSection: Bool
    /// What the tool-picker menus put in a stage's `path` when this tool is
    /// chosen. A bare name for the tools ControlBooth vendors in
    /// `Contents/Helpers` (resolved there by `PipelineRunner.resolveToolPath`);
    /// an absolute path for a system tool that lives elsewhere.
    let insertionPath: String

    init(name: String, summary: String, hasDocSection: Bool, insertionPath: String? = nil) {
        self.name = name
        self.summary = summary
        self.hasDocSection = hasDocSection
        self.insertionPath = insertionPath ?? name
    }
}

nonisolated enum KnownExternalTools {
    static let all: [KnownExternalTool] = [
        KnownExternalTool(
            name: "rtl_fm_localradio",
            summary: "RTL-SDR tuner/demodulator (LocalRadio's rtl_fm fork). Emits mono at the tuner "
                + "rate — follow with a sox stage to reach 48 kHz stereo.",
            hasDocSection: true
        ),
        KnownExternalTool(
            name: "sox",
            summary: "Audio resampler / filter. For a raw-PCM stage both sides must be described "
                + "explicitly (-r / -e signed-integer / -b 16 / -c / -t raw / -).",
            hasDocSection: true
        ),
        KnownExternalTool(
            name: "stereodemux",
            summary: "FM multiplex → stereo L/R decoder. Sits right after rtl_fm_localradio; "
                + "-r <rate> is its input rate; emits 2-channel S16LE.",
            hasDocSection: true
        ),
        KnownExternalTool(
            name: "ffmpeg",
            summary: "Vendored LGPL ffmpeg. Decodes an HTTP(S)/HLS web-radio URL to raw PCM — "
                + "give it \"-i <url> -f s16le -ar 48000 -ac 2 -\" and follow with PCMUDPSender.",
            hasDocSection: false
        ),
        KnownExternalTool(
            name: "nc",
            summary: "System netcat (/usr/bin/nc). Simple TCP/UDP plumbing — but for UDP audio "
                + "sources PCMUDPReceiver is usually the better choice.",
            hasDocSection: true,
            insertionPath: "/usr/bin/nc"
        ),
        KnownExternalTool(
            name: "nrsc5",
            summary: "HD Radio (NRSC-5) decoder — not bundled. Run it yourself and bridge in via "
                + "PCMUDPReceiver; its output is 44100 Hz stereo, so add a sox stage after.",
            hasDocSection: false
        ),
    ]

    /// The known tool for `path`, matched on a bare name or the last path
    /// component of an absolute path.
    static func match(_ path: String) -> KnownExternalTool? {
        let name = path.contains("/") ? (path as NSString).lastPathComponent : path
        guard !name.isEmpty else { return nil }
        return all.first { $0.name == name }
    }
}
