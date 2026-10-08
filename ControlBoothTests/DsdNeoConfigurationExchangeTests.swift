import Testing
import Foundation
@testable import ControlBooth

struct DsdNeoConfigurationExchangeTests {

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dsd-exchange-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleSet() -> DsdNeoConfigurationSet {
        var awin = DsdNeoConfigurationSet.awin
        awin.groupListPath = "/Users/a/lists/rndmtn.csv"
        awin.rtlSerial = "00000090"
        var set = DsdNeoConfigurationSet(configurations: [awin, DsdNeoConfigurationSet.cwin])
        set.activeID = awin.id
        return set
    }

    @Test func exportEmbedsListTextAndRoundTrips() throws {
        let data = try DsdNeoConfigurationExchange.export(sampleSet()) { path in
            path.hasSuffix("rndmtn.csv") ? "TGID,Mode,Name\n1,D,Test\n" : nil
        }
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (merged, report) = try DsdNeoConfigurationExchange.importing(
            data, into: DsdNeoConfigurationSet(configurations: []), listsFolder: folder)
        #expect(report.added == ["AWIN", "CWIN"])
        #expect(report.listsWritten == 1)
        let awin = try #require(merged.configurations.first)
        #expect(awin.controlChannels == DsdNeoConfigurationSet.awin.controlChannels)
        #expect(awin.rtlSerial == "00000090")
        #expect(awin.systemID == "BEE00-188")
        #expect(awin.groupListPath == folder.appendingPathComponent("rndmtn.csv").path)
        #expect(try String(contentsOfFile: awin.groupListPath, encoding: .utf8) == "TGID,Mode,Name\n1,D,Test\n")
        #expect(merged.configurations[1].groupListPath.isEmpty)
    }

    @Test func importKeepsExistingAndRenamesCollisions() throws {
        let data = try DsdNeoConfigurationExchange.export(sampleSet()) { _ in nil }
        let existing = sampleSet()
        let folder = tempFolder()
        let (merged, report) = try DsdNeoConfigurationExchange.importing(data, into: existing, listsFolder: folder)
        #expect(merged.configurations.prefix(2).map(\.id) == existing.configurations.map(\.id))
        #expect(merged.configurations.map(\.name) == ["AWIN", "CWIN", "AWIN 2", "CWIN 2"])
        #expect(report.renamed == ["AWIN 2", "CWIN 2"])
        #expect(merged.activeID == existing.activeID)
        #expect(merged.configurations[2].id != existing.configurations[0].id)
    }

    @Test func identicalListIsReusedDifferentListGetsNewName() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ csv: String) throws -> Data {
            try DsdNeoConfigurationExchange.export(sampleSet()) { _ in csv }
        }
        let empty = DsdNeoConfigurationSet(configurations: [])
        let first = try DsdNeoConfigurationExchange.importing(try file("a\n"), into: empty, listsFolder: folder)
        let second = try DsdNeoConfigurationExchange.importing(try file("a\n"), into: empty, listsFolder: folder)
        #expect(second.report.listsWritten == 0)
        #expect(second.set.configurations[0].groupListPath == first.set.configurations[0].groupListPath)
        let third = try DsdNeoConfigurationExchange.importing(try file("b\n"), into: empty, listsFolder: folder)
        #expect(third.set.configurations[0].groupListPath == folder.appendingPathComponent("rndmtn 2.csv").path)
    }

    @Test func listNameCannotEscapeTheFolder() throws {
        var file = DsdNeoConfigurationExchange(configurations: [
            .init(name: "X", controlChannels: [], selectedControlChannelHz: 0, rtlSerial: "",
                  systemID: nil, groupListName: "../../evil.csv", groupListCSV: "x\n")])
        file.format = DsdNeoConfigurationExchange.formatName
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (merged, _) = try DsdNeoConfigurationExchange.importing(
            try JSONEncoder().encode(file), into: DsdNeoConfigurationSet(configurations: []), listsFolder: folder)
        #expect(merged.configurations[0].groupListPath == folder.appendingPathComponent("evil.csv").path)
    }

    @Test func rejectsOtherFilesAndNewerVersions() throws {
        let folder = tempFolder()
        let empty = DsdNeoConfigurationSet(configurations: [])
        #expect(throws: DsdNeoConfigurationExchange.ExchangeError.notAConfigurationFile) {
            try DsdNeoConfigurationExchange.importing(Data("{}".utf8), into: empty, listsFolder: folder)
        }
        var future = DsdNeoConfigurationExchange(configurations: [])
        future.version = 99
        #expect(throws: DsdNeoConfigurationExchange.ExchangeError.newerVersion(99)) {
            try DsdNeoConfigurationExchange.importing(try JSONEncoder().encode(future), into: empty, listsFolder: folder)
        }
    }
}
