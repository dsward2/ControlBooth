import Foundation
import GRDB

final class AppDatabase {
    static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("AppDatabase initialization failed: \(error)")
        }
    }()

    let dbQueue: DatabaseQueue

    convenience init() throws {
        try self.init(path: try AppDatabase.databaseURL().path)
    }

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(self.dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_pipeline") { db in
            try db.create(table: "pipeline") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("stages_json", .text).notNull()
                t.column("destination_host", .text).notNull().defaults(to: "127.0.0.1")
                t.column("destination_port", .integer).notNull().defaults(to: 6019)
            }
            try seedExamplePipelines(db)
        }
        m.registerMigration("v2_scheduled_event") { db in
            try db.create(table: "scheduled_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().defaults(to: "New Event")
                t.column("pipeline_id", .integer).notNull()
                t.column("days_of_week", .integer).notNull().defaults(to: 62)    // Mon–Fri
                t.column("start_time_seconds", .integer).notNull().defaults(to: 32400) // 9:00 AM
                t.column("duration_seconds", .integer).notNull().defaults(to: 3600)
                t.column("is_enabled", .boolean).notNull().defaults(to: true)
            }
        }
        m.registerMigration("v3_recording_directory") { db in
            try db.alter(table: "scheduled_event") { t in
                t.add(column: "recording_directory", .text)
            }
        }
        m.registerMigration("v4_airplay_receiver_settings") { db in
            try db.create(table: "airplay_receiver_settings") { t in
                t.column("id", .integer).primaryKey()
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("device_name", .text).notNull().defaults(to: "ControlBooth")
                t.column("destination_host", .text).notNull().defaults(to: "127.0.0.1")
                t.column("destination_port", .integer).notNull().defaults(to: 6019)
            }
            try db.execute(sql: """
                INSERT INTO airplay_receiver_settings (id, enabled, device_name, destination_host, destination_port)
                VALUES (1, 0, 'ControlBooth', '127.0.0.1', 6019)
                """)
        }
        return m
    }

    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ControlBooth", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ControlBooth.sqlite3")
    }

    /// Example pipelines so Start/Stop is testable on first launch. The tool paths
    /// point at binaries on this machine (AntennaHead's vendored sox and the
    /// PipelineHelpers package build); they are ordinary rows — edit or delete
    /// them freely.
    private static func seedExamplePipelines(_ db: Database) throws {
        let antennaHeadRoot = "/Volumes/ExternalSSD/Users/dsward/Documents/Claude working directory/AntennaHead"
        let pipelineHelpersRoot = "/Volumes/ExternalSSD/Users/dsward/Documents/Claude working directory/PipelineHelpers"
        let soxPath = "\(antennaHeadRoot)/sox"

        // PCMSpeechSynth meters its own output in real time, so it won't flood the
        // UDP receiver the way an unpaced generator (e.g. sox synth) would.
        var speech = Pipeline.prototype(name: "Speech Test (example)")
        speech.stages = [
            PipelineStage(
                path: "\(pipelineHelpersRoot)/.build/arm64-apple-macosx/release/PCMSpeechSynth",
                arguments: ["--text", "This is a ControlBooth pipeline test.", "--repeat", "--gap", "2"]
            ),
            PipelineStage(
                path: soxPath,
                arguments: [
                    "-q", "--buffer", "2205",
                    "-r", "22050", "-e", "signed-integer", "-b", "16", "-c", "1", "-t", "raw", "-",
                    "-e", "signed-integer", "-b", "16", "-c", "2", "-t", "raw", "-",
                    "rate", "48000"
                ]
            )
        ]
        try speech.insert(db)

        // Template for the real use case: nrsc5 can't run inside sandboxed
        // AntennaHead, but ControlBooth is unsandboxed. nrsc5 emits WAV on stdout
        // (-o -); sox converts to the raw 48 kHz / 2 ch S16LE contract.
        var nrsc5 = Pipeline.prototype(name: "nrsc5 HD Radio (example — edit path & frequency)")
        nrsc5.stages = [
            PipelineStage(
                path: "/opt/local/bin/nrsc5",
                arguments: ["-q", "-o", "-", "88.5", "0"]
            ),
            PipelineStage(
                path: soxPath,
                arguments: [
                    "-q", "-t", "wav", "-",
                    "-e", "signed-integer", "-b", "16", "-c", "2", "-t", "raw", "-",
                    "rate", "48000"
                ]
            )
        ]
        try nrsc5.insert(db)
    }
}
