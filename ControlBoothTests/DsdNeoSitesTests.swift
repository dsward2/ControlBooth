import Testing
import Foundation
@testable import ControlBooth

/// Learning sites and applying the user's talkgroup overrides. Log lines are
/// verbatim from DSD-neo v2.8.1 on AWIN (WACN BEE00, system 188).
struct DsdNeoSitesTests {

    @Test func parsesSiteAndChannelLines() {
        #expect(DsdNeoLogParser.parse("  LRA [00] SYSID [188] RFSS ID [002] SITE ID [038] CHAN [015D] SSC [70] ")
                == .homeSite(system: "188", rfss: 2, site: 38, channel: 0x015D))
        #expect(DsdNeoLogParser.parse(" Adjacent Site Status Broadcast - LRA 00 SYS 188 RFSS 1 Site 75 CH 01D7 SSC 70")
                == .adjacentSite(system: "188", rfss: 1, site: 75, channel: 0x01D7))
        #expect(DsdNeoLogParser.parse("  P25 FREQ: map ch=0x01D7 -> 853.950000 MHz")
                == .channelFrequency(channel: 0x01D7, hertz: 853_950_000))
        #expect(DsdNeoLogParser.parse("  P25 FREQ: iden=1 type=1 ch=0x1449 -> 770.856250 MHz (base5=764000000Hz spac125=6250Hz)")
                == .channelFrequency(channel: 0x1449, hertz: 770_856_250))
    }

    @Test func networkIDFromSyncLine() {
        let id = DsdNeoLogParser.networkID(in: "13:08:54 Sync: +P25p1 WACN: BEE00; SYS: 188; NAC/CC: 18C; RFSS: 002; Site: 038;  TDULC")
        #expect(id == DsdNeoNetworkID(wacn: "BEE00", system: "188"))
        #expect(id?.id == "BEE00-188")
        #expect(DsdNeoLogParser.networkID(in: "20:24:10 Sync: +P25p1 NAC: 000; duid:EE") == nil)
    }

    @Test func siteTableFiltersCorruptBroadcasts() {
        var table = DsdNeoSiteTable()
        let now = Date()
        // Neighbours before the home system is known are ignored.
        table.noteAdjacent(system: "188", rfss: 1, site: 75, channel: 0x01D7, at: now)
        #expect(table.sites.isEmpty)

        table.noteHome(system: "188", rfss: 2, site: 38, channel: 0x015D, at: now)
        for _ in 0..<5 { table.noteAdjacent(system: "188", rfss: 1, site: 75, channel: 0x01D7, at: now) }
        // One corrupt channel among many good ones, another system's ID, and
        // a site heard only twice.
        table.noteAdjacent(system: "188", rfss: 1, site: 75, channel: 0xF499, at: now)
        table.noteAdjacent(system: "1C1", rfss: 100, site: 10, channel: 0x0459, at: now)
        table.noteAdjacent(system: "188", rfss: 1, site: 5, channel: 0x033D, at: now)
        table.noteAdjacent(system: "188", rfss: 1, site: 5, channel: 0x033D, at: now)

        table.noteFrequency(channel: 0x015D, hertz: 853_187_500)
        table.noteFrequency(channel: 0x01D7, hertz: 853_950_000)
        table.noteFrequency(channel: 0x0005, hertz: 16_388_393_255)   // poisoned band plan

        let listed = table.listedSites
        #expect(listed.map(\.id) == ["2-38", "1-75"])
        #expect(listed[0].isHome)
        #expect(listed[1].channel == 0x01D7)
        #expect(table.frequency(of: listed[0]) == 853_187_500)
        #expect(table.frequency(of: listed[1]) == 853_950_000)
        #expect(table.channelFrequencies[0x0005] == nil)
    }

    @Test func siteTableRoundTripsThroughJSON() throws {
        var table = DsdNeoSiteTable()
        table.noteHome(system: "188", rfss: 2, site: 38, channel: 0x015D, at: Date(timeIntervalSince1970: 1_000))
        table.noteFrequency(channel: 0x015D, hertz: 853_187_500)
        let data = try JSONEncoder().encode(table)
        #expect(try JSONDecoder().decode(DsdNeoSiteTable.self, from: data) == table)
    }

    @Test func systemKeyPrefersNetworkIdentity() {
        var settings = DsdNeoScannerSettings()
        settings.controlChannelHz = 853_187_500
        #expect(settings.systemKey == "cc-853187500")
        settings.systemID = "BEE00-188"
        #expect(settings.systemKey == "sys-BEE00-188")
    }

    @Test func settingsSavedBeforeSystemIDStillDecode() throws {
        let old = #"{"rtlSerial":"00000180","controlChannelHz":853187500,"gainDB":48,"ppm":-2,"bandwidthKHz":24,"groupListPath":"","encryptionLockout":true,"audioPort":23480,"extraArguments":[]}"#
        let settings = try JSONDecoder().decode(DsdNeoScannerSettings.self, from: Data(old.utf8))
        #expect(settings.systemID == nil)
        #expect(settings.rtlSerial == "00000180")
    }

    @Test func ledgerSavedBeforeLastHeardStillDecodes() throws {
        // As phase 2 wrote it (talkgroups-cc-853187500.json).
        let old = #"{"counts":{"3":{"clear":3,"encrypted":0},"30250":{"clear":5,"encrypted":0}}}"#
        let ledger = try JSONDecoder().decode(DsdNeoTalkgroupLedger.self, from: Data(old.utf8))
        #expect(ledger.counts[3]?.clear == 3)
        #expect(ledger.counts[3]?.lastHeard == nil)
    }

    @Test func overridesPrecedence() {
        let list = DsdNeoGroupList(csv: """
            DEC,Mode,Name,Tag,FullName
            3,A,ASP Tr A,ASP,State Police Troop A
            30147,A,LR PD Main,Pulaski Co,Little Rock PD Main
            44720,A,PCSO Pri 1,Pulaski Co,Pulaski Sheriff Primary 1
            100,B,Blocked In List,Tag,Blocked In List
            """)
        var overrides = DsdNeoTalkgroupOverrides()
        overrides.setPolicy(.allow, for: 44720)          // beats the encryption lockout
        overrides.setPolicy(.lockOut, for: 3)            // manual lockout
        overrides.setPolicy(.allow, for: 100)            // beats the list's own B
        overrides.setName("Faulkner Co Sheriff Dispatch, North", for: 19402)   // not in the list
        overrides.setName("LRPD Main Dispatch", for: 30147)

        let result = list.applying(overrides, encryptedLockouts: [30147, 44720, 53790])
        let byTG = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.talkgroup, $0) })
        #expect(byTG[3]?.mode == "B")
        #expect(byTG[30147]?.mode == "DE")
        #expect(byTG[30147]?.name == "LRPD Main Dispatch")
        #expect(byTG[30147]?.fields[4] == "LRPD Main Dispatch")
        #expect(byTG[44720]?.mode == "A")
        #expect(byTG[100]?.mode == "A")
        #expect(byTG[53790]?.fields == ["53790", "DE", "Encrypted TG 53790", "Encrypted", ""])
        #expect(byTG[19402]?.fields == ["19402", "A", "Faulkner Co Sheriff Dispatch; North", "",
                                        "Faulkner Co Sheriff Dispatch; North"])
        #expect(result.displayNames[19402] == "Faulkner Co Sheriff Dispatch, North")
    }

    @Test func overridePolicyAndNames() {
        var overrides = DsdNeoTalkgroupOverrides()
        overrides.setPolicy(.lockOut, for: 5)
        #expect(overrides.policy(for: 5) == .lockOut)
        overrides.setPolicy(.allow, for: 5)
        #expect(overrides.policy(for: 5) == .allow)
        #expect(!overrides.lockedOut.contains(5))
        overrides.setPolicy(.automatic, for: 5)
        #expect(overrides.policy(for: 5) == .automatic)
        overrides.setName("  Fire  ", for: 7)
        #expect(overrides.names[7] == "Fire")
        overrides.setName("", for: 7)
        #expect(overrides.names[7] == nil)
    }

    @MainActor
    @Test func talkgroupRowsMergeListHistoryAndOverrides() {
        let list = DsdNeoGroupList(csv: "DEC,Mode,Name\n3,A,ASP Tr A\n1449,A,Fire\n")
        var ledger = DsdNeoTalkgroupLedger()
        for _ in 0..<3 { ledger.record(DsdNeoCallRecord(talkgroup: 53790, source: 1, encrypted: true, isGroupCall: true)) }
        ledger.record(DsdNeoCallRecord(talkgroup: 3, source: 1, encrypted: false, isGroupCall: true))
        var overrides = DsdNeoTalkgroupOverrides()
        overrides.setName("Unknown Ops", for: 53643)

        let rows = Dictionary(uniqueKeysWithValues: DsdNeoTalkgroupRow.rows(
            list: list, ledger: ledger, overrides: overrides, encryptionLockout: true).map { ($0.id, $0) })
        #expect(Set(rows.keys) == [3, 1449, 53790, 53643])
        #expect(rows[3]?.clearCalls == 1)
        #expect(rows[3]?.inList == true)
        #expect(rows[1449]?.heard == false)
        #expect(rows[53790]?.encryptionLocked == true)
        #expect(rows[53643]?.name == "Unknown Ops")
        #expect(rows[53643]?.inList == false)
    }
}
