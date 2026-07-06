import Foundation
import Observation
import PipelineRunner

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
    }

    func stop(_ pipeline: Pipeline) {
        guard let id = pipeline.id, let manager = managers[id] else { return }
        manager.terminate()
        managers[id] = nil
    }

    func stopAll() {
        for manager in managers.values {
            manager.terminate()
        }
        managers.removeAll()
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
