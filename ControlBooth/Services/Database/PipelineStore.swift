import Foundation
import GRDB
import Observation
import SwiftUI
import SharedLogging

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
            LogStore.shared.log(.error, source: "PipelineStore", "load failed: \(error)")
            pipelines = []
        }
    }

    static let dsdNeoScannerPipelineName = "dsd-neo Scanner"
    private static let dsdNeoScannerSeededKey = "dsdNeoScanner.pipelineSeeded"

    /// Adds the "dsd-neo Scanner" pipeline — a single `dsd-neo-scanner` stage —
    /// the first time dsd-neo is found installed, so AntennaHead can list it
    /// like any other pipeline. Only once: a user who deletes it keeps it
    /// deleted.
    func seedDsdNeoScannerPipelineIfNeeded(defaults: UserDefaults = .standard,
                                           installed: Bool = DsdNeoInstallation.detect() != nil) {
        guard installed, !defaults.bool(forKey: Self.dsdNeoScannerSeededKey) else { return }
        defaults.set(true, forKey: Self.dsdNeoScannerSeededKey)
        let exists = pipelines.contains { $0.stages.first.map(PipelineRunner.isDsdNeoScannerStage) == true }
        guard !exists else { return }
        var pipeline = Pipeline.prototype(name: Self.dsdNeoScannerPipelineName,
                                          sortOrder: (pipelines.map(\.sortOrder).max() ?? -1) + 1)
        pipeline.stages = [PipelineStage(path: PipelineRunner.dsdNeoScannerTool)]
        do {
            try save(pipeline)
            LogStore.shared.log(.info, source: "PipelineStore", "added the \(Self.dsdNeoScannerPipelineName) pipeline")
        } catch {
            LogStore.shared.log(.error, source: "PipelineStore", "could not add the dsd-neo Scanner pipeline: \(error)")
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
            LogStore.shared.log(.error, source: "PipelineStore", "move failed: \(error)")
        }
    }

    func delete(_ pipeline: Pipeline) throws {
        guard let id = pipeline.id else { return }
        _ = try dbQueue.write { db in
            try Pipeline.deleteOne(db, key: id)
        }
        load()
    }

    /// Copies `pipeline` into a new row placed immediately after the original,
    /// shifting later pipelines down.
    @discardableResult
    func duplicate(_ pipeline: Pipeline) throws -> Pipeline {
        var newPipeline = pipeline
        newPipeline.id = nil
        newPipeline.name = "\(pipeline.name) copy"
        newPipeline.sortOrder = pipeline.sortOrder

        let saved = try dbQueue.write { db -> Pipeline in
            try newPipeline.insert(db)
            // The copy shares sort_order with the original; breaking ties by
            // id (the copy is always the higher id) places it right after.
            let ordered = try Pipeline.order(Column("sort_order"), Column("id")).fetchAll(db)
            for (index, var record) in ordered.enumerated() {
                record.sortOrder = index
                try record.update(db)
            }
            return try Pipeline.fetchOne(db, key: newPipeline.id)!
        }
        load()
        return saved
    }
}
