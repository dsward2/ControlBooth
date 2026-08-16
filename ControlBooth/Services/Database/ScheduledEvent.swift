import Foundation
import GRDB

struct ScheduledEvent: Codable, Identifiable, Hashable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var pipelineId: Int64
    var daysOfWeek: Int          // bitmask: bit 0 = Sunday, bit 1 = Monday … bit 6 = Saturday
    var startTimeSeconds: Int    // seconds since midnight (0–86399)
    var durationSeconds: Int
    var isEnabled: Bool
    /// Whether this event's audio gets recorded. The destination folder is
    /// not ControlBooth's to pick — it's configured once, globally, in
    /// AntennaHead's own Settings (AntennaHead is sandboxed; a folder picked
    /// here in unsandboxed ControlBooth carries no sandbox access grant it
    /// could use).
    var isRecordingEnabled: Bool
    /// Only consulted when `isRecordingEnabled` is true. `false` (default)
    /// is today's behavior: the pipeline's final stage streams to AntennaHead
    /// over UDP for live playback, and AntennaHead records the stream itself
    /// (the 'RecS'/'RecP' AppleEvents in `AntennaHeadClient`). `true` —
    /// "recording only" — skips AntennaHead entirely: the pipeline's final
    /// stage is PipelineHelpers' `LiveAudioRecorder`, encoding straight to a
    /// local AAC file in the shared Recordings folder. No UDP output means no
    /// contention for AntennaHead's UDP input port, so a recording-only event
    /// can run concurrently alongside any number of other pipelines.
    var recordingOnly: Bool

    static let databaseTableName = "scheduled_event"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case pipelineId          = "pipeline_id"
        case daysOfWeek          = "days_of_week"
        case startTimeSeconds    = "start_time_seconds"
        case durationSeconds     = "duration_seconds"
        case isEnabled           = "is_enabled"
        case isRecordingEnabled  = "recording_enabled"
        case recordingOnly       = "recording_only"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func prototype(pipelineId: Int64) -> ScheduledEvent {
        ScheduledEvent(
            id: nil,
            name: "New Event",
            pipelineId: pipelineId,
            daysOfWeek: 0b0111110,  // Mon–Fri
            startTimeSeconds: 9 * 3600,
            durationSeconds: 3600,
            isEnabled: true,
            isRecordingEnabled: false,
            recordingOnly: false
        )
    }

    func isDayEnabled(_ weekday: Int) -> Bool {
        daysOfWeek & (1 << weekday) != 0
    }

    mutating func setDay(_ weekday: Int, enabled: Bool) {
        if enabled {
            daysOfWeek |= (1 << weekday)
        } else {
            daysOfWeek &= ~(1 << weekday)
        }
    }

    // Returns the next wall-clock Date this event would fire after `now`.
    func nextFireDate(after now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        for daysAhead in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: daysAhead, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: day) - 1  // 0 = Sun … 6 = Sat
            guard isDayEnabled(weekday) else { continue }
            let fireDate = day.addingTimeInterval(TimeInterval(startTimeSeconds))
            if fireDate > now { return fireDate }
        }
        return nil
    }
}
