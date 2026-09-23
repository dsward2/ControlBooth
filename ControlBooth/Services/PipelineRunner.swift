import Foundation
import Observation
import PipelineRunner
import SDRDeviceAccess
import SharedLogging

/// Runs Pipeline records as chains of helper processes. Each running pipeline
/// gets its own TaskPipelineManager, so several pipelines can run concurrently.
/// Every pipeline is terminated by an automatically appended PCMUDPSender stage
/// that delivers the PCM stream to AntennaHead over UDP.
@MainActor
@Observable
final class PipelineRunner {
    enum RunnerError: Error, CustomStringConvertible {
        case notSaved
        case alreadyRunning(String)
        case noStages(String)
        case senderMissing
        case recorderMissing
        case toolMissing(String)
        /// A stage's RTL-SDR is busy or missing (see `RTLSDRPreflight`).
        case deviceUnavailable(RTLSDRPreflightReport)
        /// "Quit Gqrx and Start" couldn't get Gqrx to quit.
        case gqrxDidNotQuit(String)

        var description: String {
            switch self {
            case .notSaved:
                return "Save the pipeline before starting it."
            case .alreadyRunning(let name):
                return "Pipeline '\(name)' is already running."
            case .noStages(let name):
                return "Pipeline '\(name)' has no stages."
            case .senderMissing:
                return "PCMUDPSender is missing from Contents/Helpers — add it to the Copy Files build phase (see SETUP.md)."
            case .recorderMissing:
                return "LiveAudioRecorder is missing from Contents/Helpers — add it to the Copy Files build phase (see SETUP.md)."
            case .toolMissing(let path):
                return "Tool not found or not executable: \(path)"
            case .deviceUnavailable(let report):
                return report.message
            case .gqrxDidNotQuit(let why):
                return why
            }
        }
    }

    /// What a pipeline's automatically-appended final stage does with the PCM
    /// stream the user-defined stages produce.
    enum PipelineOutput {
        /// Default: appends PCMUDPSender, streaming PCM to AntennaHead over UDP
        /// (`pipeline.destinationHost`/`destinationPort`) for live playback —
        /// and, if the caller separately drives AntennaHead's recorder, for
        /// AntennaHead-side recording too. Contends with any other running
        /// pipeline sending to the same destination (see `start(_:output:)`).
        case udpToAntennaHead
        /// Appends PipelineHelpers' `LiveAudioRecorder` instead, encoding the
        /// PCM stream straight to an AAC file at `aacPath`. No UDP output at
        /// all, so a pipeline started this way never contends for — and is
        /// never stopped on account of — AntennaHead's UDP input port.
        case recordingOnly(aacPath: String)
    }

    private(set) var managers: [Int64: TaskPipelineManager] = [:]

    /// Destination (host, port) each currently-started pipeline is sending
    /// to, keyed by pipeline id. Used only to catch two pipelines racing to
    /// the same destination before they can interleave into one garbled UDP
    /// stream (AntennaHead's receiver has no way to tell the streams apart).
    /// Every lookup rechecks the corresponding manager's live `.status`
    /// first, so an entry left behind by a pipeline that crashed or was
    /// stopped elsewhere can never cause a false "in use" rejection.
    private var startedDestinations: [Int64: (name: String, host: String, port: Int)] = [:]

    func manager(for pipeline: Pipeline) -> TaskPipelineManager? {
        guard let id = pipeline.id else { return nil }
        return managers[id]
    }

    func isRunning(_ pipeline: Pipeline) -> Bool {
        manager(for: pipeline)?.status == .running
    }

    /// Pipelines whose UI Play is waiting on AntennaHead's reply, so a second
    /// click during that wait can't start the pipeline twice.
    private var startsInFlight: Set<Int64> = []

    /// Set when a start was refused because Gqrx holds the pipeline's RTL-SDR:
    /// the pipeline and its `-d` value, for the error alert's "Quit Gqrx and
    /// Start" button (`quitGqrxAndStart()`), which shows only while the alert
    /// displays this refusal's `message`. Cleared by any successful start.
    private(set) var gqrxQuitOffer: (pipeline: Pipeline, device: String, message: String)?

    /// The Play buttons' entry point: tells AntennaHead the pipeline is
    /// starting (so it opens its receiver and shows the pipeline name on its
    /// Remote Control view), *then* starts it. Only for UI-initiated starts.
    /// AntennaHead's own Listen and the scripting commands call `start(_:)`
    /// directly — AntennaHead already knows about those, and echoing back would
    /// have the two apps send each other blocking events at the same moment.
    ///
    /// Only pipelines aimed at this Mac are announced: a pipeline sending to
    /// another host isn't AntennaHead's to listen to.
    func startAnnouncingToAntennaHead(_ pipeline: Pipeline) async throws {
        guard let id = pipeline.id, !startsInFlight.contains(id) else { return }
        let announced = Self.isLoopback(pipeline.destinationHost)
        let name = pipeline.name
        if announced {
            startsInFlight.insert(id)
            defer { startsInFlight.remove(id) }
            // Off the main thread: the send blocks until AntennaHead replies.
            await Task.detached(priority: .userInitiated) {
                AntennaHeadClient.announcePipelineStarting(name)
            }.value
        }
        do {
            try start(pipeline)
        } catch {
            // AntennaHead opened its receiver for a pipeline that isn't
            // coming (e.g. its RTL-SDR is busy): send it back to its filler.
            if announced {
                Task.detached(priority: .utility) { AntennaHeadClient.announcePipelineStopped(name) }
            }
            throw error
        }
    }

    /// The Stop buttons' entry point: stops the pipeline, then tells AntennaHead
    /// so it returns to its filler and updates its Remote Control view.
    func stopAnnouncingToAntennaHead(_ pipeline: Pipeline) {
        let wasRunning = isRunning(pipeline)
        stop(pipeline)
        guard wasRunning, Self.isLoopback(pipeline.destinationHost) else { return }
        let name = pipeline.name
        Task.detached(priority: .utility) { AntennaHeadClient.announcePipelineStopped(name) }
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func lastFailure(for pipeline: Pipeline) -> TaskPipelineManager.Failure? {
        manager(for: pipeline)?.lastFailure
    }

    func start(_ pipeline: Pipeline, output: PipelineOutput = .udpToAntennaHead) throws {
        guard let id = pipeline.id else {
            throw RunnerError.notSaved
        }
        if let existing = managers[id] {
            guard existing.status != .running else {
                throw RunnerError.alreadyRunning(pipeline.name)
            }
            managers[id] = nil
        }

        // Two pipelines sharing a UDP destination would interleave into one
        // garbled stream, so rather than reject the new pipeline, stop
        // whichever other pipeline is already sending to the same place —
        // switching pipelines should just work, not require a manual Stop
        // first. terminateAndWait blocks until it's actually gone, so the
        // hardware/port it held is free before we launch the replacement.
        // A `.recordingOnly` pipeline sends no UDP at all, so it can never be
        // in contention with anything — this whole check is skipped for it,
        // both as the new pipeline (it never stops another) and, since it's
        // never recorded into `startedDestinations` below, as the "other"
        // pipeline a later `.udpToAntennaHead` start might otherwise compare
        // against.
        if case .udpToAntennaHead = output {
            for (otherID, otherManager) in managers where otherID != id && otherManager.status == .running {
                guard let dest = startedDestinations[otherID],
                      dest.host == pipeline.destinationHost,
                      dest.port == pipeline.destinationPort else { continue }
                otherManager.terminateAndWait()
                managers[otherID] = nil
                startedDestinations[otherID] = nil
            }
        }

        let stages = pipeline.stages
        guard !stages.isEmpty else {
            throw RunnerError.noStages(pipeline.name)
        }

        // Check each RTL-SDR the stages will open is actually free, after any
        // pipeline stopped above has released its hardware. A busy or missing
        // dongle fails the start with the likely holder named, instead of a
        // pipeline whose rtl stage dies (or, with an older librtlsdr, runs on
        // silently with no device).
        for device in Self.rtlsdrDevices(in: stages) {
            let report = RTLSDRPreflight.check(device: device, backend: LibRTLSDRBackend())
            guard report.isAvailable else {
                gqrxQuitOffer = report.gqrxIsHolder ? (pipeline, device, report.message) : nil
                LogStore.shared.log(.error, source: "PipelineRunner",
                                    "'\(pipeline.name)': \(report.message)")
                throw RunnerError.deviceUnavailable(report)
            }
        }

        let finalStagePath: String
        switch output {
        case .udpToAntennaHead:
            finalStagePath = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/PCMUDPSender").path
            guard FileManager.default.isExecutableFile(atPath: finalStagePath) else {
                throw RunnerError.senderMissing
            }
        case .recordingOnly:
            finalStagePath = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/LiveAudioRecorder").path
            guard FileManager.default.isExecutableFile(atPath: finalStagePath) else {
                throw RunnerError.recorderMissing
            }
        }

        let manager = TaskPipelineManager()
        manager.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
        for stage in stages {
            let toolPath = Self.resolveToolPath(stage.path)
            guard FileManager.default.isExecutableFile(atPath: toolPath) else {
                throw RunnerError.toolMissing(stage.path)
            }
            let item = manager.makeTaskItem(
                pathToExecutable: toolPath,
                functionName: (stage.path as NSString).lastPathComponent
            )
            for argument in stage.arguments {
                item.addArgument(argument)
            }
            manager.add(item)
        }

        switch output {
        case .udpToAntennaHead:
            // The sender's --exit-with-parent watchdog makes it exit if this app
            // dies (even on crash/SIGKILL); as the downstream-most reader it then
            // collapses the whole chain upstream via SIGPIPE, so no stages are
            // orphaned.
            let sender = manager.makeTaskItem(pathToExecutable: finalStagePath, functionName: "PCMUDPSender")
            sender.addArgument("--host")
            sender.addArgument(pipeline.destinationHost)
            sender.addArgument("--port")
            sender.addArgument(pipeline.destinationPort)
            sender.addArgument("--exit-with-parent")
            manager.add(sender)
        case .recordingOnly(let aacPath):
            // No --exit-with-parent watchdog here (LiveAudioRecorder has none):
            // it's the pipeline's own terminal reader, so when this app dies
            // and the whole process tree is reaped, or `stop()`/`stopAll()`
            // terminates every stage directly, it goes down the same way any
            // other stage does.
            let recorder = manager.makeTaskItem(pathToExecutable: finalStagePath, functionName: "LiveAudioRecorder")
            recorder.addArgument("--aac")
            recorder.addArgument(aacPath)
            manager.add(recorder)
        }

        try manager.start()
        managers[id] = manager
        gqrxQuitOffer = nil
        if case .udpToAntennaHead = output {
            startedDestinations[id] = (pipeline.name, pipeline.destinationHost, pipeline.destinationPort)
        }
    }

    /// Blocks until the pipeline's processes have actually exited (see
    /// `TaskItem.terminateAndWait`), so a `start()` for a replacement
    /// pipeline right after this returns reliably finds any exclusive
    /// hardware device or destination port the old pipeline held released.
    func stop(_ pipeline: Pipeline) {
        guard let id = pipeline.id, let manager = managers[id] else { return }
        manager.terminateAndWait()
        managers[id] = nil
        startedDestinations[id] = nil
    }

    func stopAll() {
        for manager in managers.values {
            manager.terminateAndWait()
        }
        managers.removeAll()
        startedDestinations.removeAll()
    }

    /// The error alert's "Quit Gqrx and Start": quits Gqrx — a normal quit,
    /// never a kill — which holds the dongle the refused pipeline needs
    /// (stopping Gqrx's DSP isn't enough: it keeps the device open from
    /// launch), then starts the pipeline.
    func quitGqrxAndStart() async throws {
        guard let offer = gqrxQuitOffer else { return }
        gqrxQuitOffer = nil
        let device = offer.device
        let (quit, report) = await Task.detached(priority: .userInitiated) {
            RTLSDRPreflight.quitGqrxAndRecheck(device: device, backend: LibRTLSDRBackend())
        }.value
        if case .failed(let why) = quit, !report.isAvailable {
            throw RunnerError.gqrxDidNotQuit(why)
        }
        guard report.isAvailable else { throw RunnerError.deviceUnavailable(report) }
        try await startAnnouncingToAntennaHead(offer.pipeline)
    }

    /// librtlsdr-based tools a stage can run, by executable name.
    static let rtlsdrTools: Set<String> = [
        "rtl_fm_localradio", "rtl_fm", "rtl_sdr", "rtl_tcp", "rtl_power",
        "rtl_adsb", "rtl_433", "rtl_test", "nrsc5",
    ]

    /// The RTL-SDR device values (`-d`, or index 0 when absent) the stages
    /// will open, in order, without duplicates. Skips stages that don't open
    /// a local dongle: nrsc5 reading from rtl_tcp (`-H`) or a file (`-r`), and
    /// rtl_433's non-RTL SoapySDR device strings (`-d driver=…`).
    static func rtlsdrDevices(in stages: [PipelineStage]) -> [String] {
        var devices: [String] = []
        for stage in stages {
            let tool = (stage.path as NSString).lastPathComponent
            guard rtlsdrTools.contains(tool) else { continue }
            let args = stage.arguments
            if tool == "nrsc5", args.contains("-H") || args.contains("-r") { continue }
            var device = "0"
            if let i = args.firstIndex(of: "-d"), i + 1 < args.count {
                device = args[i + 1]
            } else if let attached = args.first(where: { $0.hasPrefix("-d") && $0.count > 2 }) {
                device = String(attached.dropFirst(2))   // getopt's "-d1" form
            }
            if tool == "rtl_433" {
                if device.contains("=") { continue }
                if device.hasPrefix(":") { device.removeFirst() }   // ":serial"
            }
            if !devices.contains(device) { devices.append(device) }
        }
        return devices
    }

    /// Bare tool names resolve to the app bundle's Contents/Helpers directory;
    /// anything containing "/" is used as given — ControlBooth is unsandboxed,
    /// so absolute paths like /opt/local/bin/nrsc5 work directly.
    static func resolveToolPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.contains("/") else {
            return expanded
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(expanded)")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper.path
        }
        return expanded
    }
}
