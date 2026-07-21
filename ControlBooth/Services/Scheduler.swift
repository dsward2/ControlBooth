import Foundation
import Observation

@MainActor
@Observable
final class Scheduler {
    private(set) var nextFireDate: Date?
    private(set) var lastError: String?
    private var schedulerTask: Task<Void, Never>?

    /// Cancels any running schedule loop and starts a fresh one.
    /// Call whenever the event list changes or on app start.
    func reschedule(events: [ScheduledEvent], pipelineStore: PipelineStore, runner: PipelineRunner) {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            await self?.loop(events: events, pipelineStore: pipelineStore, runner: runner)
        }
    }

    func cancelSchedule() {
        schedulerTask?.cancel()
        schedulerTask = nil
        nextFireDate = nil
    }

    private func loop(events: [ScheduledEvent], pipelineStore: PipelineStore, runner: PipelineRunner) async {
        let enabled = events.filter(\.isEnabled)
        var searchAfter = Date()

        while !Task.isCancelled {
            guard let next = Self.soonestFire(from: enabled, after: searchAfter) else {
                nextFireDate = nil
                break
            }

            nextFireDate = next.date
            let delay = next.date.timeIntervalSince(Date())
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { break }

            if let pipeline = pipelineStore.pipeline(withID: next.event.pipelineId) {
                if let dir = next.event.recordingDirectory {
                    let path = Self.makeRecordingPath(eventName: next.event.name, directory: dir)
                    do {
                        try AntennaHeadClient.startRecording(toPath: path)
                    } catch {
                        lastError = "Recording start failed for '\(next.event.name)': \(error)"
                    }
                }
                do {
                    try runner.start(pipeline)
                } catch {
                    lastError = "Pipeline start failed for '\(next.event.name)': \(error)"
                }
                let pipelineId = next.event.pipelineId
                let duration = next.event.durationSeconds
                let hasRecording = next.event.recordingDirectory != nil
                Task { [weak self, weak runner] in
                    try? await Task.sleep(for: .seconds(TimeInterval(duration)))
                    if hasRecording {
                        do {
                            try AntennaHeadClient.stopRecording()
                        } catch {
                            self?.lastError = "Recording stop failed for '\(next.event.name)': \(error)"
                        }
                    }
                    guard let runner, let pipeline = pipelineStore.pipeline(withID: pipelineId) else { return }
                    runner.stop(pipeline)
                }
            }

            searchAfter = next.date.addingTimeInterval(1)
        }
    }

    private struct NextFire {
        let date: Date
        let event: ScheduledEvent
    }

    static func makeRecordingPath(eventName: String, directory: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let safeName = eventName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: directory).appendingPathComponent("\(safeName)_\(timestamp).aac").path
    }

    private static func soonestFire(from events: [ScheduledEvent], after now: Date) -> NextFire? {
        events.compactMap { event -> NextFire? in
            guard let date = event.nextFireDate(after: now) else { return nil }
            return NextFire(date: date, event: event)
        }.min(by: { $0.date < $1.date })
    }
}
