import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class PipelineStore {
    private(set) var pipelines: [Pipeline] = []

    @ObservationIgnored
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = AppDatabase.shared.dbQueue) {
        self.dbQueue = dbQueue
        load()
    }

    func load() {
        do {
            pipelines = try dbQueue.read { db in
                try Pipeline.order(Column("id")).fetchAll(db)
            }
        } catch {
            print("PipelineStore - load failed: \(error)")
            pipelines = []
        }
    }

    func pipeline(withID id: Int64) -> Pipeline? {
        pipelines.first { $0.id == id }
    }

    @discardableResult
    func save(_ pipeline: Pipeline) throws -> Pipeline {
        var record = pipeline
        try dbQueue.write { db in
            try record.save(db)
        }
        load()
        return record
    }

    @discardableResult
    func createNew() throws -> Pipeline {
        try save(Pipeline.prototype())
    }

    func delete(_ pipeline: Pipeline) throws {
        guard let id = pipeline.id else { return }
        _ = try dbQueue.write { db in
            try Pipeline.deleteOne(db, key: id)
        }
        load()
    }
}
