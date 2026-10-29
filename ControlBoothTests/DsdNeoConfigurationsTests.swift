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

    @Test func seedsTheBuiltInSystemsWithTheMatchingOneActive() {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 854_362_500
        settings.groupListPath = "/tmp/cwin-group.csv"
        settings.rtlSerial = "00000180"
        let set = DsdNeoConfigurationSet.seeded(matching: settings)
        #expect(set.configurations.map(\.name) == ["AWIN", "CWIN", "UCA (DMR)", "FCARC DMR (W5AUU-16)"])
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
        #expect(set.configurations.count == 5)
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
        let cwin = try #require(set.configurations.first { $0.name == "CWIN" })

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

    // MARK: DMR

    @Test func ucaIsABuiltInConventionalDmrSystem() {
        let uca = DsdNeoConfigurationSet.ucaDMR
        #expect(uca.effectiveSystemType == .dmrConventional)
        #expect(uca.controlChannels.map(\.hz) == [467_212_500, 467_262_500, 155_625_000, 155_415_000])
        #expect(uca.selectedControlChannelHz == 467_212_500)
        #expect(uca.rtlSerial == "")
        #expect(DsdNeoConfiguration.parseChannels(uca.channelsText) == uca.controlChannels)
    }

    @Test func existingConfigurationsAreToppedUpOnceWithUca() throws {
        let old = DsdNeoConfigurationSet(configurations: [DsdNeoConfigurationSet.awin, DsdNeoConfigurationSet.cwin])
        #expect(old.builtinsVersion == nil)
        let topped = old.toppedUpWithBuiltins()
        #expect(topped.configurations.map(\.name) == ["AWIN", "CWIN", "UCA (DMR)", "FCARC DMR (W5AUU-16)"])
        #expect(topped.builtinsVersion == DsdNeoConfigurationSet.currentBuiltinsVersion)

        // A user who deletes it keeps it deleted.
        var deleted = topped
        deleted.configurations.removeAll { $0.name == "UCA (DMR)" }
        #expect(deleted.toppedUpWithBuiltins().configurations.count == 3)

        // It is not added twice when a configuration of that name exists.
        var named = old
        named.configurations.append(DsdNeoConfigurationSet.ucaDMR)
        #expect(named.toppedUpWithBuiltins().configurations.count == 4)
    }

    @Test func fcarcIsABuiltInConventionalDmrSystemAddedToVersion2Sets() {
        let fcarc = DsdNeoConfigurationSet.fcarcDMR
        #expect(fcarc.effectiveSystemType == .dmrConventional)
        #expect(fcarc.controlChannels.map(\.hz) == [443_750_000, 145_210_000])
        #expect(fcarc.selectedControlChannelHz == 443_750_000)
        let v2 = DsdNeoConfigurationSet(configurations: [DsdNeoConfigurationSet.awin, DsdNeoConfigurationSet.ucaDMR],
                                        builtinsVersion: 2)
        #expect(v2.toppedUpWithBuiltins().configurations.map(\.name) == ["AWIN", "UCA (DMR)", "FCARC DMR (W5AUU-16)"])
    }

    @Test func aSavedSetWithoutDmrFieldsStillDecodes() throws {
        let json = #"{"configurations":[{"id":"7C1A2C0E-0D0E-4A0C-9E1B-0A5B8A3B1F11","name":"AWIN","controlChannels":[{"hz":853187500,"label":""}],"selectedControlChannelHz":853187500,"groupListPath":"","rtlSerial":"00000180"}]}"#
        let set = try JSONDecoder().decode(DsdNeoConfigurationSet.self, from: Data(json.utf8))
        #expect(set.configurations[0].systemType == nil)
        #expect(set.configurations[0].effectiveSystemType == .p25Trunked)
        #expect(set.builtinsVersion == nil)
    }

    @Test func choosingAConfigurationSetsTheSystemType() throws {
        let set = DsdNeoConfigurationSet.seeded(matching: DsdNeoScannerSettings())
        let uca = DsdNeoConfigurationSet.ucaDMR
        let dmr = try #require(set.selecting(uca.id, controlChannelHz: 155_625_000, from: DsdNeoScannerSettings()))
        #expect(dmr.settings.effectiveSystemType == .dmrConventional)
        #expect(dmr.settings.controlChannelHz == 155_625_000)
        #expect(dmr.set.active?.selectedControlChannelHz == 155_625_000)

        let back = try #require(dmr.set.selecting(DsdNeoConfigurationSet.awin.id, from: dmr.settings))
        #expect(back.settings.effectiveSystemType == .p25Trunked)
    }

    @Test func recordingSettingsKeepsTheSystemType() throws {
        var set = DsdNeoConfigurationSet.seeded(matching: DsdNeoScannerSettings())
        let uca = DsdNeoConfigurationSet.ucaDMR
        let chosen = try #require(set.selecting(uca.id, from: DsdNeoScannerSettings()))
        set = chosen.set
        var settings = chosen.settings
        settings.controlChannelHz = 467_262_500
        set.record(settings)
        #expect(set.active?.effectiveSystemType == .dmrConventional)
        #expect(set.active?.selectedControlChannelHz == 467_262_500)
    }

    @Test func aSeededMatchRespectsTheSystemType() {
        // A P25 setting on a frequency a DMR configuration also lists must not pick the DMR one.
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 467_212_500
        let set = DsdNeoConfigurationSet.seeded(matching: settings)
        #expect(set.active?.effectiveSystemType == .p25Trunked)
        #expect(set.active?.name == "Current")
    }
}
