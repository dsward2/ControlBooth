import Testing
import Foundation
@testable import ControlBooth

/// The dsd-neo Scanner's pure logic: reading dsd-neo's log output, the
/// talkgroup list and encrypted-talkgroup lockout, the watchdog, and the
/// command line. Log lines are verbatim from DSD-neo v2.8.1 on a P25 system.
struct DsdNeoLogParserTests {

    @Test func clearAndEncryptedGrants() {
        #expect(DsdNeoLogParser.parse("  SVC [04] CHAN [1421] Group [3] Source [14525561]")
                == .grant(talkgroup: 3, encrypted: false))
        #expect(DsdNeoLogParser.parse("  SVC [44] CHAN [1449] Group [30147] Source [7438106]")
                == .grant(talkgroup: 30147, encrypted: true))
    }

    @Test func stateMachineLines() {
        #expect(DsdNeoLogParser.parse("[P25 SM] ON_CC -> TUNED (grant)") == .tunedToGrant)
        #expect(DsdNeoLogParser.parse("[P25 SM] cc-lost") == .controlChannelLost)
        // The transition line announcing the same loss isn't counted twice.
        #expect(DsdNeoLogParser.parse("[P25 SM] ON_CC -> HUNT (cc-lost)") == nil)
    }

    @Test func voiceChannelUsers() {
        #expect(DsdNeoLogParser.parse(" Group Voice Channel User - Group 3 Source 0")
                == .voiceUser(talkgroup: 3, encrypted: false))
        #expect(DsdNeoLogParser.parse(" Encrypted Group Voice Channel User - Group 30147 Source 7438106")
                == .voiceUser(talkgroup: 30147, encrypted: true))
    }

    @Test func retunesSyncAndDevice() {
        #expect(DsdNeoLogParser.parse("Retune applied: 3508522367 Hz.") == .retune(hertz: 3_508_522_367))
        #expect(DsdNeoLogParser.parse("20:24:30 Sync: +P25p1 WACN: BEE00; SYS: 188; NAC/CC: 18C;  LDU2  ")
                == .p25Sync)
        #expect(DsdNeoLogParser.parse("NOTICE: Selected Device #1 with Serial Number: 00000180 ")
                == .selectedDevice(index: 1, serial: "00000180"))
    }

    @Test func phase2SyncCountsAsSignal() {
        #expect(DsdNeoLogParser.parse("13:26:28 Sync: +P25p2 WACN: BEE00; SYS: 188; NAC/CC: 18C;") == .p25Sync)
    }

    @Test func colorCodesAreIgnored() {
        #expect(DsdNeoLogParser.parse("\u{1B}[0m20:24:31 Sync: +P25p1 \u{1B}[36mWACN: BEE00;\u{1B}[0m LDU1")
                == .p25Sync)
    }

    @Test func unrelatedLines() {
        #expect(DsdNeoLogParser.parse("Tuner gain set to 48.00 dB.") == nil)
        #expect(DsdNeoLogParser.parse("") == nil)
    }
}

struct DsdNeoCallRecordTests {

    @Test func clearAndEncryptedCalls() throws {
        let clear = try #require(DsdNeoCallRecord(eventLogLine:
            "2026-09-25 12:56:23 P25p1 TGT: 00044720; SRC: 07701644; NAC: 18C; NET_STS: BEE00:188:2.38; "
            + "Group; TName: Pulaski Co Sheriff Primary 1; Mode: A;  "))
        #expect(clear == DsdNeoCallRecord(talkgroup: 44720, source: 7_701_644, encrypted: false, isGroupCall: true))

        let encrypted = try #require(DsdNeoCallRecord(eventLogLine:
            "2026-09-25 12:56:42 P25p1 TGT: 00044720; SRC: 09770565; NAC: 18C; NET_STS: BEE00:188:2.38; "
            + "ENC; ALG: AA; KID: AA85; Group; TName: Pulaski Co Sheriff Primary 1; Mode: A;"))
        #expect(encrypted.encrypted)
        #expect(encrypted.talkgroup == 44720)
    }

    @Test func headerLinesAreNotCalls() {
        #expect(DsdNeoCallRecord(eventLogLine: "2026-09-25 12:56:12 DSD-neo Started and Event History Initialized; ") == nil)
    }
}

struct DsdNeoTalkgroupTests {

    private let csv = """
        DEC,Mode,Name,Tag,FullName (generated from rndmtn.tsv by tsv2group.py)
        3,A,ASP Tr A LR South Districtwide Disp,ASP,State Police: Troop A - Little Rock South - Districtwide Dispatch
        19405,A,Faulkner Co Greenbrier,Faulkner Co,Faulkner County (23) Greenbrier; Mayflower; and Vilonia Police
        30147,A,Pulaski Co LR PD Main Disp,Pulaski Co,Pulaski County (60) Little Rock Police - Main Dispatch
        53790,DE,Encrypted TG 53790,Encrypted,(not in rndmtn.tsv)
        """

    @Test func parsesRowsAndPrefersFullNames() {
        let list = DsdNeoGroupList(csv: csv)
        #expect(list.rows.count == 4)
        let names = list.displayNames
        #expect(names[3] == "State Police: Troop A - Little Rock South - Districtwide Dispatch")
        #expect(names[19405] == "Faulkner County (23) Greenbrier, Mayflower, and Vilonia Police")
        // A "(…)" note in the FullName column falls back to the Name column.
        #expect(names[53790] == "Encrypted TG 53790")
    }

    @Test func plainDsdNeoListUsesNameColumn() {
        let list = DsdNeoGroupList(csv: "DEC,Mode,Name,Tag\n1449,A,Fire Dispatch,Fire\n")
        #expect(list.displayNames == [1449: "Fire Dispatch"])
    }

    @Test func lockoutMarksDEAndAddsMissingRows() {
        let locked = DsdNeoGroupList(csv: csv).applyingLockout([30147, 29379])
        #expect(locked.rows.first { $0.talkgroup == 30147 }?.mode == "DE")
        #expect(locked.rows.first { $0.talkgroup == 3 }?.mode == "A")
        let added = locked.rows.first { $0.talkgroup == 29379 }
        // The list has a FullName column, so added rows carry it (empty).
        #expect(added?.fields == ["29379", "DE", "Encrypted TG 29379", "Encrypted", ""])
        // Everything else round-trips unchanged.
        let text = locked.csvText
        #expect(text.hasPrefix("DEC,Mode,Name,Tag,FullName"))
        #expect(text.contains("3,A,ASP Tr A LR South Districtwide Disp,ASP,State Police:"))
    }

    @Test func ledgerLocksOutOnlyConsistentlyEncryptedTalkgroups() {
        var ledger = DsdNeoTalkgroupLedger()
        func call(_ tg: Int, encrypted: Bool, group: Bool = true) -> DsdNeoCallRecord {
            DsdNeoCallRecord(talkgroup: tg, source: 1, encrypted: encrypted, isGroupCall: group)
        }
        for _ in 0..<DsdNeoTalkgroupLedger.lockoutThreshold - 1 { ledger.record(call(30147, encrypted: true)) }
        #expect(ledger.lockedOut.isEmpty)
        ledger.record(call(30147, encrypted: true))
        #expect(ledger.lockedOut == [30147])

        // A talkgroup that has carried a clear call is never locked out.
        ledger.record(call(44720, encrypted: false))
        for _ in 0..<10 { ledger.record(call(44720, encrypted: true)) }
        #expect(!ledger.lockedOut.contains(44720))

        // Private (unit-to-unit) calls don't count.
        for _ in 0..<5 { ledger.record(call(777, encrypted: true, group: false)) }
        #expect(!ledger.lockedOut.contains(777))
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        var ledger = DsdNeoTalkgroupLedger()
        ledger.record(DsdNeoCallRecord(talkgroup: 3, source: 1, encrypted: false, isGroupCall: true))
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(DsdNeoTalkgroupLedger.self, from: data) == ledger)
    }
}

struct DsdNeoWatchdogTests {

    @Test func restartsOnImpossibleRetune() {
        var watchdog = DsdNeoWatchdog()
        let realControl = watchdog.observe(.retune(hertz: 851_975_000))
        let realVoice = watchdog.observe(.retune(hertz: 770_856_250))
        let poisoned = watchdog.observe(.retune(hertz: 3_508_522_367))
        #expect(realControl == nil)
        #expect(realVoice == nil)
        #expect(poisoned == .invalidRetune(hertz: 3_508_522_367))
    }

    @Test func restartsAfterRepeatedControlChannelLoss() {
        var watchdog = DsdNeoWatchdog()
        var results: [DsdNeoWatchdog.Reason?] = []
        for _ in 0..<DsdNeoWatchdog.maxConsecutiveLosses {
            results.append(watchdog.observe(.controlChannelLost))
        }
        #expect(results.dropLast().allSatisfy { $0 == nil })
        #expect(results.last == .controlChannelLost(times: DsdNeoWatchdog.maxConsecutiveLosses))
    }

    @Test func syncResetsTheLossCount() {
        var watchdog = DsdNeoWatchdog()
        var results: [DsdNeoWatchdog.Reason?] = []
        for _ in 0..<20 {
            results.append(watchdog.observe(.controlChannelLost))
            results.append(watchdog.observe(.p25Sync))
        }
        #expect(results.allSatisfy { $0 == nil })
    }

    @Test func silenceIsAReasonToRestart() {
        let launch = Date()
        var watchdog = DsdNeoWatchdog(now: launch)
        let early = watchdog.checkSilence(at: launch.addingTimeInterval(DsdNeoWatchdog.silenceLimit - 1))
        let late = watchdog.checkSilence(at: launch.addingTimeInterval(DsdNeoWatchdog.silenceLimit + 1))
        #expect(early == nil)
        #expect(late == .noSignal(seconds: Int(DsdNeoWatchdog.silenceLimit)))

        // A sync restarts the silence clock.
        _ = watchdog.observe(.p25Sync, at: launch.addingTimeInterval(50))
        let afterSync = watchdog.checkSilence(at: launch.addingTimeInterval(DsdNeoWatchdog.silenceLimit + 1))
        #expect(afterSync == nil)
        // Other events don't.
        _ = watchdog.observe(.tunedToGrant, at: launch.addingTimeInterval(100))
        let stillSilent = watchdog.checkSilence(at: launch.addingTimeInterval(50 + DsdNeoWatchdog.silenceLimit + 1))
        #expect(stillSilent != nil)
    }

    @Test func restartBudgetGivesUpThenRecovers() {
        var budget = DsdNeoRestartBudget()
        let start = Date()
        var allowed: [Bool] = []
        for i in 0..<DsdNeoRestartBudget.maxRestarts {
            allowed.append(budget.allowRestart(at: start.addingTimeInterval(Double(i))))
        }
        let overBudget = budget.allowRestart(at: start.addingTimeInterval(10))
        let afterWindow = budget.allowRestart(at: start.addingTimeInterval(DsdNeoRestartBudget.window + 10))
        #expect(allowed.allSatisfy { $0 })
        #expect(!overBudget)
        #expect(afterWindow)
    }
}

struct DsdNeoSettingsTests {

    private var awin: DsdNeoScannerSettings {
        var settings = DsdNeoScannerSettings()
        settings.rtlSerial = "00000180"
        settings.controlChannelHz = 853_187_500
        settings.gainDB = 48
        settings.ppm = -2
        return settings
    }

    @Test func commandLine() {
        let args = awin.arguments(rtlIndex: 1, groupListPath: "/tmp/groups.csv", eventLogPath: "/tmp/events.log")
        #expect(args == ["-ft", "-i", "rtl:1:853.1875M:48:-2:24:0:2", "-T",
                         "-G", "/tmp/groups.csv", "--enc-lockout",
                         "-o", "udp:127.0.0.1:23480", "-J", "/tmp/events.log",
                         "--frontend", "terminal"])
    }

    @Test func optionalPartsAndExtras() {
        var settings = awin
        settings.encryptionLockout = false
        settings.gainDB = 43.9
        settings.extraArguments = ["-W"]
        let args = settings.arguments(rtlIndex: 0, groupListPath: nil, eventLogPath: "/e")
        #expect(args.contains("rtl:0:853.1875M:43.9:-2:24:0:2"))
        #expect(!args.contains("-G"))
        #expect(!args.contains("--enc-lockout"))
        #expect(args.last == "-W")
    }

    @Test func megahertzFormatting() {
        #expect(DsdNeoScannerSettings.megahertz(853_187_500) == "853.1875M")
        #expect(DsdNeoScannerSettings.megahertz(851_000_000) == "851M")
        #expect(DsdNeoScannerSettings.megahertz(460_025_000) == "460.025M")
    }

    @Test func configurationAndPersistence() throws {
        #expect(!DsdNeoScannerSettings().isConfigured)
        #expect(awin.isConfigured)
        let defaults = try #require(UserDefaults(suiteName: "DsdNeoSettingsTests-\(UUID().uuidString)"))
        awin.save(to: defaults)
        #expect(DsdNeoScannerSettings.load(from: defaults) == awin)
    }
}

struct DsdNeoPipelineStagesTests {

    @Test func scannerStageExpandsToFillingReceiverAndResample() {
        let stages = PipelineRunner.dsdNeoScannerStages(audioPort: 23480)
        #expect(stages.map(\.path) == ["PCMUDPReceiver", "sox"])
        #expect(stages[0].arguments == ["--port", "23480", "--fill-silence",
                                        "--rate", "8000", "--channels", "2", "--exit-with-parent"])
        #expect(stages[1].arguments.suffix(2) == ["rate", "48000"])
        #expect(PipelineRunner.isDsdNeoScannerStage(PipelineStage(path: "dsd-neo-scanner")))
        #expect(!PipelineRunner.isDsdNeoScannerStage(PipelineStage(path: "/Applications/dsd-neo-macos/bin/dsd-neo")))
    }

    @Test func lineBufferSplitsAcrossChunks() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("Retune applied: 85".utf8)).isEmpty)
        #expect(buffer.append(Data("1975000 Hz.\r\n[P25 SM] cc-lost\npartial".utf8))
                == ["Retune applied: 851975000 Hz.", "[P25 SM] cc-lost"])
        #expect(buffer.flush() == "partial")
        #expect(buffer.flush() == nil)
    }
}

@MainActor
struct DsdNeoScannerViewTests {

    @Test func controlChannelFieldParsing() {
        #expect(DsdNeoScannerView.hertz(fromMegahertz: "853.1875") == 853_187_500)
        #expect(DsdNeoScannerView.hertz(fromMegahertz: " 853.1875 MHz ") == 853_187_500)
        #expect(DsdNeoScannerView.hertz(fromMegahertz: "770.85625") == 770_856_250)
        #expect(DsdNeoScannerView.hertz(fromMegahertz: "") == nil)
        #expect(DsdNeoScannerView.hertz(fromMegahertz: "abc") == nil)
        #expect(DsdNeoScannerView.hertz(fromMegahertz: "-5") == nil)
    }

    @Test func fieldShowsSavedFrequencyWithoutUnit() {
        // The tab fills the MHz field from `megahertz(_:)` minus its "M".
        #expect(DsdNeoScannerSettings.megahertz(853_187_500).dropLast() == "853.1875")
    }
}
