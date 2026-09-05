import Foundation
import Observation

@MainActor
@Observable
final class Scheduler {
    private(set) var nextFireDate: Date?
    private(set) var lastError: String?
    /// Output filename of each scheduled event currently in its fired window
    /// with recording actually underway, keyed by event id — covers both
    /// recording-only (LiveAudioRecorder is the pipeline's own terminal
    /// stage) and record-with-playback (a separate AntennaHead 'RecS'
    /// AppleEvent) modes. An entry is only added once its recording
    /// mechanism has actually started successfully, and is always removed
    /// by the same per-fire Task that stops it, so this stays accurate even
    /// across `reschedule()`/delete of the event.
    private(set) var recordingFilenames: [Int64: String] = [:]
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
                // Recording-only: skip AntennaHead entirely. The pipeline's own
                // final stage (LiveAudioRecorder, appended by PipelineRunner)
                // writes the AAC file directly, so starting/stopping the
                // pipeline *is* starting/stopping the recording — no 'RecS'/
                // 'RecP' AppleEvent round-trip needed, and no UDP output means
                // no contention with any other running pipeline.
                let recordingOnly = next.event.isRecordingEnabled && next.event.recordingOnly
                var recordingFilename: String?
                if recordingOnly {
                    let filename = Self.makeRecordingFilename(eventName: next.event.name)
                    if let folderURL = SharedRecordingFolder.url {
                        let aacPath = folderURL.appendingPathComponent(filename).path
                        do {
                            try runner.start(pipeline, output: .recordingOnly(aacPath: aacPath))
                            recordingFilename = filename
                        } catch {
                            lastError = "Pipeline start failed for '\(next.event.name)': \(error)"
                        }
                    } else {
                        lastError = "Recording start failed for '\(next.event.name)': the shared Recordings folder isn't available — check the App Group entitlement."
                    }
                } else {
                    if next.event.isRecordingEnabled {
                        let filename = Self.makeRecordingFilename(eventName: next.event.name)
                        do {
                            try AntennaHeadClient.startRecording(filename: filename)
                            recordingFilename = filename
                        } catch {
                            lastError = "Recording start failed for '\(next.event.name)': \(error)"
                        }
                    }
                    do {
                        try runner.start(pipeline)
                    } catch {
                        lastError = "Pipeline start failed for '\(next.event.name)': \(error)"
                    }
                }
                if let filename = recordingFilename, let id = next.event.id {
                    recordingFilenames[id] = filename
                }
                let pipelineId = next.event.pipelineId
                let duration = next.event.durationSeconds
                let stopsAntennaHeadRecording = next.event.isRecordingEnabled && !recordingOnly
                Task { [weak self, weak runner] in
                    try? await Task.sleep(for: .seconds(TimeInterval(duration)))
                    if stopsAntennaHeadRecording {
                        do {
                            try AntennaHeadClient.stopRecording()
                        } catch {
                            self?.lastError = "Recording stop failed for '\(next.event.name)': \(error)"
                        }
                    }
                    defer {
                        if let id = next.event.id {
                            self?.recordingFilenames.removeValue(forKey: id)
                        }
                    }
                    // For recording-only, this is what actually finalizes the
                    // file — stopping LiveAudioRecorder closes it.
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

    static func makeRecordingFilename(eventName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let safeName = eventName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safeName)_\(timestamp).aac"
    }

    private static func soonestFire(from events: [ScheduledEvent], after now: Date) -> NextFire? {
        events.compactMap { event -> NextFire? in
            guard let date = event.nextFireDate(after: now) else { return nil }
            return NextFire(date: date, event: event)
        }.min(by: { $0.date < $1.date })
    }
}
