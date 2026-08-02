import Foundation
import Observation
import PipelineRunner
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
        case toolMissing(String)

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
            case .toolMissing(let path):
                return "Tool not found or not executable: \(path)"
            }
        }
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

    func lastFailure(for pipeline: Pipeline) -> TaskPipelineManager.Failure? {
        manager(for: pipeline)?.lastFailure
    }

    func start(_ pipeline: Pipeline) throws {
        guard let id = pipeline.id else {
            throw RunnerError.notSaved
        }
        if let existing = managers[id] {
            guard existing.status != .running else {
                throw RunnerError.alreadyRunning(pipeline.name)
            }
            managers[id] = nil
        }

        // Two pipelines sharing a destination would interleave into one
        // garbled stream, so rather than reject the new pipeline, stop
        // whichever other pipeline is already sending to the same place —
        // switching pipelines should just work, not require a manual Stop
        // first. terminateAndWait blocks until it's actually gone, so the
        // hardware/port it held is free before we launch the replacement.
        for (otherID, otherManager) in managers where otherID != id && otherManager.status == .running {
            guard let dest = startedDestinations[otherID],
                  dest.host == pipeline.destinationHost,
                  dest.port == pipeline.destinationPort else { continue }
            otherManager.terminateAndWait()
            managers[otherID] = nil
            startedDestinations[otherID] = nil
        }

        let stages = pipeline.stages
        guard !stages.isEmpty else {
            throw RunnerError.noStages(pipeline.name)
        }

        let senderPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PCMUDPSender").path
        guard FileManager.default.isExecutableFile(atPath: senderPath) else {
            throw RunnerError.senderMissing
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

        // The sender's --exit-with-parent watchdog makes it exit if this app dies
        // (even on crash/SIGKILL); as the downstream-most reader it then collapses
        // the whole chain upstream via SIGPIPE, so no stages are orphaned.
        let sender = manager.makeTaskItem(pathToExecutable: senderPath, functionName: "PCMUDPSender")
        sender.addArgument("--host")
        sender.addArgument(pipeline.destinationHost)
        sender.addArgument("--port")
        sender.addArgument(pipeline.destinationPort)
        sender.addArgument("--exit-with-parent")
        manager.add(sender)

        try manager.start()
        managers[id] = manager
        startedDestinations[id] = (pipeline.name, pipeline.destinationHost, pipeline.destinationPort)
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
