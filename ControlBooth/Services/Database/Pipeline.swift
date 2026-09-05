import Foundation
import GRDB

struct Pipeline: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var stagesJson: String
    var destinationHost: String
    var destinationPort: Int
    var sortOrder: Int

    static let databaseTableName = "pipeline"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case stagesJson = "stages_json"
        case destinationHost = "destination_host"
        case destinationPort = "destination_port"
        case sortOrder = "sort_order"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func prototype(name: String = "New Pipeline", sortOrder: Int = 0) -> Pipeline {
        Pipeline(
            id: nil,
            name: name,
            stagesJson: PipelineStage.encode([]),
            destinationHost: "127.0.0.1",
            destinationPort: 6019,
            sortOrder: sortOrder
        )
    }

    var stages: [PipelineStage] {
        get { PipelineStage.decode(stagesJson) }
        set { stagesJson = PipelineStage.encode(newValue) }
    }
}

/// One tool invocation in a pipeline. Serialized as the same
/// `{"tasks":[{"path":"...","arguments":[...]}]}` JSON that AntennaHead uses
/// for its custom tasks, so stage definitions can be moved between the apps.
struct PipelineStage: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var arguments: [String]

    init(path: String = "", arguments: [String] = []) {
        self.path = path
        self.arguments = arguments
    }

    private struct StageDTO: Codable {
        var path: String
        var arguments: [String]
    }

    private struct TasksDTO: Codable {
        var tasks: [StageDTO]
    }

    static func decode(_ json: String) -> [PipelineStage] {
        guard let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(TasksDTO.self, from: data) else {
            return []
        }
        return dto.tasks.map { PipelineStage(path: $0.path, arguments: $0.arguments) }
    }

    static func encode(_ stages: [PipelineStage]) -> String {
        let dto = TasksDTO(tasks: stages.map { StageDTO(path: $0.path, arguments: $0.arguments) })
        guard let data = try? JSONEncoder().encode(dto),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"tasks":[]}"#
        }
        return json
    }
}

extension Array where Element == PipelineStage {
    /// Finds a stage whose executable matches `toolName` (by last path
    /// component, the same identity `PipelineRunner` uses for a stage's
    /// `functionName`) and returns the `UInt16` value of its
    /// `--control-port` argument, if present.
    ///
    /// Unlike AntennaHead's fixed, internally-owned control ports, a
    /// ControlBooth pipeline's spatial-audio stage is just whatever the
    /// pipeline author typed into that stage's arguments in the editor —
    /// there's no app-owned constant to read. This discovers it from the
    /// pipeline's own configuration instead of assuming one.
    func controlPort(forTool toolName: String) -> UInt16? {
        for stage in self {
            guard (stage.path as NSString).lastPathComponent == toolName else { continue }
            guard let index = stage.arguments.firstIndex(of: "--control-port"),
                  index + 1 < stage.arguments.count,
                  let port = UInt16(stage.arguments[index + 1]) else { continue }
            return port
        }
        return nil
    }
}
