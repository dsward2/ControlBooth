import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class ScheduledEventStore {
    private(set) var events: [ScheduledEvent] = []

    @ObservationIgnored
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = AppDatabase.shared.dbQueue) {
        self.dbQueue = dbQueue
        load()
    }

    func load() {
        do {
            events = try dbQueue.read { db in
                try ScheduledEvent.order(Column("id")).fetchAll(db)
            }
        } catch {
            print("ScheduledEventStore - load failed: \(error)")
            events = []
        }
    }

    func event(withID id: Int64) -> ScheduledEvent? {
        events.first { $0.id == id }
    }

    @discardableResult
    func save(_ event: ScheduledEvent) throws -> ScheduledEvent {
        var record = event
        try dbQueue.write { db in
            try record.save(db)
        }
        load()
        return record
    }

    @discardableResult
    func createNew(pipelineId: Int64) throws -> ScheduledEvent {
        try save(ScheduledEvent.prototype(pipelineId: pipelineId))
    }

    func delete(_ event: ScheduledEvent) throws {
        guard let id = event.id else { return }
        try dbQueue.write { db in
            try ScheduledEvent.deleteOne(db, key: id)
        }
        load()
    }
}
