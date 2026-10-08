import Foundation

/// A portable file of dsd-neo configurations (AWIN, CWIN, …) for moving them
/// between Macs or keeping a backup. Each entry carries its talkgroup list's
/// CSV text rather than the list's path, which only means something on the
/// Mac that wrote it; importing writes the lists into ControlBooth's own
/// `dsd-neo/lists` folder and points the new configurations at them.
nonisolated struct DsdNeoConfigurationExchange: Codable, Equatable {
    static let formatName = "controlbooth-dsd-neo-configurations"
    static let currentVersion = 1
    static let fileExtension = "json"

    struct Entry: Codable, Equatable {
        var name: String
        var controlChannels: [DsdNeoControlChannel]
        var selectedControlChannelHz: Int
        var rtlSerial: String
        var systemID: String?
        /// The talkgroup list's file name, and its dsd-neo CSV text.
        var groupListName: String?
        var groupListCSV: String?
    }

    enum ExchangeError: Error, CustomStringConvertible, Equatable {
        case notAConfigurationFile
        case newerVersion(Int)

        var description: String {
            switch self {
            case .notAConfigurationFile: return "That isn't a ControlBooth dsd-neo configurations file."
            case .newerVersion(let v): return "That file is version \(v); this ControlBooth reads up to version \(currentVersion)."
            }
        }
    }

    struct ImportReport: Equatable {
        var added: [String] = []
        /// Imported names that were already taken and got a suffix.
        var renamed: [String] = []
        var listsWritten = 0
    }

    var format = Self.formatName
    var version = Self.currentVersion
    var configurations: [Entry]

    // MARK: Export

    /// The file contents for `set`. `readList` returns the text of a talkgroup
    /// list path (nil when it can't be read; the entry is then exported
    /// without a list).
    static func export(_ set: DsdNeoConfigurationSet, readList: (String) -> String?) throws -> Data {
        let entries = set.configurations.map { configuration -> Entry in
            let path = configuration.groupListPath
            let csv = path.isEmpty ? nil : readList(path)
            return Entry(name: configuration.name,
                         controlChannels: configuration.controlChannels,
                         selectedControlChannelHz: configuration.selectedControlChannelHz,
                         rtlSerial: configuration.rtlSerial,
                         systemID: configuration.systemID,
                         groupListName: csv == nil ? nil : (path as NSString).lastPathComponent,
                         groupListCSV: csv)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(DsdNeoConfigurationExchange(configurations: entries))
    }

    // MARK: Import

    /// `set` with the configurations in `data` added. Existing configurations
    /// are never replaced: an imported name that is already taken gets " 2",
    /// " 3", … appended. Talkgroup lists are written into `listsFolder`
    /// (reusing a file whose contents are identical, otherwise picking an
    /// unused name). The active configuration is unchanged.
    static func importing(_ data: Data, into set: DsdNeoConfigurationSet,
                          listsFolder: URL) throws -> (set: DsdNeoConfigurationSet, report: ImportReport) {
        guard let file = try? JSONDecoder().decode(DsdNeoConfigurationExchange.self, from: data),
              file.format == formatName else { throw ExchangeError.notAConfigurationFile }
        guard file.version <= currentVersion else { throw ExchangeError.newerVersion(file.version) }

        var result = set
        var report = ImportReport()
        for entry in file.configurations {
            var name = entry.name.isEmpty ? "Imported" : entry.name
            let taken = Set(result.configurations.map(\.name))
            if taken.contains(name) {
                var n = 2
                while taken.contains("\(entry.name) \(n)") { n += 1 }
                name = "\(entry.name) \(n)"
                report.renamed.append(name)
            }
            var listPath = ""
            if let csv = entry.groupListCSV {
                listPath = try writeList(csv, preferredName: entry.groupListName ?? "\(name).csv",
                                         into: listsFolder, written: &report.listsWritten)
            }
            result.configurations.append(DsdNeoConfiguration(
                name: name, controlChannels: entry.controlChannels,
                selectedControlChannelHz: entry.selectedControlChannelHz,
                groupListPath: listPath, rtlSerial: entry.rtlSerial, systemID: entry.systemID))
            report.added.append(name)
        }
        return (result, report)
    }

    private static func writeList(_ csv: String, preferredName: String, into folder: URL,
                                  written: inout Int) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the last path component, so a crafted file can't write outside the folder.
        var base = (preferredName as NSString).lastPathComponent
        if base.isEmpty || base.hasPrefix(".") { base = "talkgroups.csv" }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension.isEmpty ? "csv" : (base as NSString).pathExtension
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            if (try? String(contentsOf: candidate, encoding: .utf8)) == csv { return candidate.path }
            candidate = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        try csv.write(to: candidate, atomically: true, encoding: .utf8)
        written += 1
        return candidate.path
    }
}
