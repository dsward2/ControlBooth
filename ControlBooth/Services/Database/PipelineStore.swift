import Foundation
import GRDB
import Observation
import SwiftUI

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
                try Pipeline.order(Column("sort_order")).fetchAll(db)
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
        let nextOrder = (pipelines.map(\.sortOrder).max() ?? -1) + 1
        return try save(Pipeline.prototype(sortOrder: nextOrder))
    }

    func move(from source: IndexSet, to destination: Int) {
        var reordered = pipelines
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try dbQueue.write { db in
                for (index, var pipeline) in reordered.enumerated() {
                    pipeline.sortOrder = index
                    try pipeline.update(db)
                }
            }
            load()
        } catch {
            print("PipelineStore - move failed: \(error)")
        }
    }

    func delete(_ pipeline: Pipeline) throws {
        guard let id = pipeline.id else { return }
        _ = try dbQueue.write { db in
            try Pipeline.deleteOne(db, key: id)
        }
        load()
    }
}
