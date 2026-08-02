import Foundation
import GRDB
import Observation
import SharedLogging

@MainActor
@Observable
final class AirPlaySettingsStore {
    private(set) var settings: AirPlaySettings = .fallback()

    @ObservationIgnored
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = AppDatabase.shared.dbQueue) {
        self.dbQueue = dbQueue
        load()
    }

    func load() {
        do {
            settings = try dbQueue.read { db in
                try AirPlaySettings.fetchOne(db, key: AirPlaySettings.singletonID)
            } ?? .fallback()
        } catch {
            LogStore.shared.log(.error, source: "AirPlaySettingsStore", "load failed: \(error)")
            settings = .fallback()
        }
    }

    @discardableResult
    func save(_ newSettings: AirPlaySettings) throws -> AirPlaySettings {
        var record = newSettings
        try dbQueue.write { db in
            try record.update(db)
        }
        load()
        return record
    }
}
