import SwiftUI
import PipelineRunner

struct PipelineStatusView: View {
    @Environment(PipelineRunner.self) private var runner
    let pipeline: Pipeline

    var body: some View {
        // Periodic refresh: task liveness (process?.isRunning) isn't observable,
        // so re-render every couple of seconds while the section is visible.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                if let manager = runner.manager(for: pipeline) {
                    Text(statusLabel(manager.status))
                        .fontWeight(.medium)
                    if let failure = manager.lastFailure {
                        Text("Failed stage: \(failure.functionName) — exit status \(failure.terminationStatus) (\(failure.reason))")
                            .foregroundStyle(.red)
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

    private func statusLabel(_ status: TaskPipelineManager.Status) -> String {
        switch status {
        case .idle: return "Idle"
        case .running: return "Running"
        case .terminating: return "Terminating…"
        case .terminated: return "Terminated"
        }
    }
}
