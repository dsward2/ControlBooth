import Testing
import Foundation
@testable import ControlBooth

struct DsdNeoConfigurationsTests {

    @Test func parsesChannelLines() {
        let channels = DsdNeoConfiguration.parseChannels("""
            854.3625 Clearwell Road
            854.3875M  Collins Drive
            junk line
            856.0125
            854.3625 duplicate
            """)
        #expect(channels == [
            DsdNeoControlChannel(hz: 854_362_500, label: "Clearwell Road"),
            DsdNeoControlChannel(hz: 854_387_500, label: "Collins Drive"),
            DsdNeoControlChannel(hz: 856_012_500, label: ""),
        ])
        #expect(DsdNeoConfiguration.parseChannels("5 not a radio frequency") == [])
    }

    @Test func channelsTextRoundTrips() {
        let cwin = DsdNeoConfigurationSet.cwin
        #expect(DsdNeoConfiguration.parseChannels(cwin.channelsText) == cwin.controlChannels)
        #expect(cwin.controlChannels.first?.title == "854.3625 MHz — Clearwell Road")
    }

    @Test func seedsAwinAndCwinWithTheMatchingOneActive() {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 854_362_500
        settings.groupListPath = "/tmp/cwin-group.csv"
        settings.rtlSerial = "00000180"
        let set = DsdNeoConfigurationSet.seeded(matching: settings)
        #expect(set.configurations.map(\.name) == ["AWIN", "CWIN"])
        #expect(set.active?.name == "CWIN")
        #expect(set.active?.groupListPath == "/tmp/cwin-group.csv")
        #expect(set.active?.rtlSerial == "00000180")
        // AWIN keeps no list or dongle until it is used.
        #expect(set.configurations[0].groupListPath == "")
    }

    @Test func anUnknownSystemBecomesItsOwnConfiguration() {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 771_243_750
        let set = DsdNeoConfigurationSet.seeded(matching: settings)
        #expect(set.configurations.count == 3)
        #expect(set.active?.controlChannels.first?.hz == 771_243_750)
    }

    @Test func selectingACconfigurationFillsTheSettings() throws {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 853_187_500
        settings.rtlSerial = "00000180"
        settings.gainDB = 40
        var set = DsdNeoConfigurationSet.seeded(matching: settings)
        set.configurations[1].groupListPath = "/tmp/cwin.csv"
        set.configurations[1].rtlSerial = "00000360"
        let cwin = try #require(set.configurations.last)

        let result = try #require(set.selecting(cwin.id, controlChannelHz: 854_387_500, from: settings))
        #expect(result.settings.controlChannelHz == 854_387_500)
        #expect(result.settings.groupListPath == "/tmp/cwin.csv")
        #expect(result.settings.rtlSerial == "00000360")
        #expect(result.settings.gainDB == 40)            // shared settings are untouched
        #expect(result.settings.systemID == "927FA-00A")
        #expect(result.set.activeID == cwin.id)
        #expect(result.set.active?.selectedControlChannelHz == 854_387_500)
    }

    @Test func selectingWithoutAChannelUsesTheLastOne() throws {
        var set = DsdNeoConfigurationSet.seeded(matching: DsdNeoScannerSettings())
        set.configurations[1].selectedControlChannelHz = 856_012_500
        let result = try #require(set.selecting(set.configurations[1].id, from: DsdNeoScannerSettings()))
        #expect(result.settings.controlChannelHz == 856_012_500)
    }

    @Test func aChannelThatIsNotListedIsRefused() {
        let set = DsdNeoConfigurationSet.seeded(matching: DsdNeoScannerSettings())
        #expect(set.selecting(set.configurations[0].id, controlChannelHz: 854_362_500, from: DsdNeoScannerSettings()) == nil)
        #expect(set.selecting(UUID(), from: DsdNeoScannerSettings()) == nil)
    }

    @Test func recordingSettingsUpdatesTheActiveConfiguration() throws {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 853_187_500
        var set = DsdNeoConfigurationSet.seeded(matching: settings)
        settings.controlChannelHz = 852_912_500          // a channel AWIN doesn't list yet
        settings.groupListPath = "/tmp/awin.csv"
        settings.rtlSerial = "00000090"
        settings.systemID = "BEE00-188"
        set.record(settings)
        let awin = try #require(set.active)
        #expect(awin.selectedControlChannelHz == 852_912_500)
        #expect(awin.channel(at: 852_912_500) != nil)
        #expect(awin.groupListPath == "/tmp/awin.csv")
        #expect(awin.rtlSerial == "00000090")
        #expect(set.configurations[1].groupListPath == "")   // CWIN untouched
    }

    @Test func storageRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "DsdNeoConfigurationsTests-\(UUID())"))
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 854_362_500
        settings.save(to: defaults)            // saving settings records into the set
        let loaded = DsdNeoConfigurationSet.load(settings: settings, from: defaults)
        #expect(loaded.active?.name == "CWIN")
        #expect(loaded == DsdNeoConfigurationSet.load(settings: DsdNeoScannerSettings(), from: defaults))
    }
}
