import SwiftUI
import PipelineRunner

struct PipelineStatusView: View {
    @Environment(PipelineRunner.self) private var runner
    let pipeline: Pipeline

    // Not persisted — same "in-session only" choice AntennaHead's Now
    // Playing sliders make. Resets to the reference position each time this
    // view appears rather than remembering the last value across runs.
    @State private var distance: Double = 1.0
    @State private var azimuth: Double = 0
    @State private var elevation: Double = 0

    var body: some View {
        // Periodic refresh: task liveness (process?.isRunning) isn't observable,
        // so re-render every couple of seconds while the section is visible.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                if let manager = runner.manager(for: pipeline) {
                    PipelineDiagramView(stages: diagramStages(manager))
                    Text(statusLabel(manager.status))
                        .fontWeight(.medium)
                    if let failure = manager.lastFailure {
                        Text("Failed stage: \(failure.functionName) — exit status \(failure.terminationStatus) (\(failure.reason))")
                            .foregroundStyle(.red)
                    }
                    if manager.status == .running {
                        spatialControls
                    }
                    Text(manager.tasksInfoString())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Not running")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Live position controls for a running pipeline's `PCMDistanceGain` /
    /// `PCMBinauralPanner` stages, if it has any — discovered from the
    /// pipeline's own configured `--control-port` arguments (see
    /// `Array<PipelineStage>.controlPort(forTool:)`), since unlike
    /// AntennaHead's fixed internal ports, ControlBooth doesn't own or
    /// assign these; the pipeline author typed them into the stage's
    /// arguments in the editor. Shows nothing for a pipeline with neither
    /// stage — this is additive to the generic pipeline editor, not a
    /// requirement of it.
    @ViewBuilder
    private var spatialControls: some View {
        let stages = pipeline.stages
        let binauralPort = stages.controlPort(forTool: "PCMBinauralPanner")
        let distancePort = stages.controlPort(forTool: "PCMDistanceGain")
        if binauralPort != nil || distancePort != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spatial Position").font(.headline)
                if let binauralPort {
                    spatialRow("Azimuth", value: $azimuth, range: -180...180, format: "%.0f\u{00B0}") { newValue in
                        SpatialControlSender.sendPosition(azimuth: newValue, elevation: elevation, toPort: binauralPort)
                    }
                    spatialRow("Elevation", value: $elevation, range: -90...90, format: "%.0f\u{00B0}") { newValue in
                        SpatialControlSender.sendPosition(azimuth: azimuth, elevation: newValue, toPort: binauralPort)
                    }
                }
                if distancePort != nil || binauralPort != nil {
                    // Distance now matters to both stages for their own
                    // distinct purposes — PCMDistanceGain for loudness
                    // falloff, PCMBinauralPanner for air absorption (moved
                    // there from PCMDistanceGain) — so a change goes to
                    // whichever of the two are actually present.
                    spatialRow("Distance", value: $distance, range: 0.1...4.0, format: "%.2f") { newValue in
                        if let distancePort { SpatialControlSender.sendDistance(newValue, toPort: distancePort) }
                        if let binauralPort { SpatialControlSender.sendDistance(newValue, toPort: binauralPort) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func spatialRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                            format: String, onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, newValue in onChange(newValue) }
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func diagramStages(_ manager: TaskPipelineManager) -> [PipelineDiagramView.DiagramStage] {
        manager.taskItems.map { item in
            let pid = item.process?.processIdentifier ?? 0
            let running = item.process?.isRunning ?? false
            return PipelineDiagramView.DiagramStage(
                name: item.functionName,
                detail: running ? "PID \(pid)" : "stopped",
                path: item.path,
                args: item.argsArray,
                running: running
            )
        }
    }

    private func statusLabel(_ status: TaskPipelineManager.Status) -> String {
        switch status {
        case .idle: return "Idle"
        case .running: return "Running"
        case .terminating: return "Terminating…"
        case .terminated: return "Terminated"
        }
    }
}
