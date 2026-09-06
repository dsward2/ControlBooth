import Foundation

/// Tools ControlBooth doesn't bundle but that `pipelinetools.html` documents.
/// Used only to show a one-line hint in the generic (non-catalogued) stage
/// editor — anything with a `PipelineHelperCatalog` spec gets the structured
/// editor instead, and truly unknown tools get nothing.
nonisolated struct KnownExternalTool: Equatable {
    let name: String
    let summary: String
    /// Whether `pipelinetools.html` carries a dedicated `<h3>` section for it
    /// (asserted by `PipelineToolsDocTests`).
    let hasDocSection: Bool
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
            name: "nc",
            summary: "System netcat (/usr/bin/nc). Simple TCP/UDP plumbing — but for UDP audio "
                + "sources PCMUDPReceiver is usually the better choice.",
            hasDocSection: true
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
