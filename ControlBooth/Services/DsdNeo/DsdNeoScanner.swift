import Foundation
import Observation
import SharedLogging

/// Runs dsd-neo for the "dsd-neo Scanner" pipeline: trunk-follows one P25
/// system on one RTL-SDR, with dsd-neo's terminal UI on a pseudo-terminal (for
/// the dsd-neo Scanner tab) and its decoded audio sent over UDP to the
/// pipeline's `PCMUDPReceiver --fill-silence` stage.
///
/// On top of plain dsd-neo it adds what running it unattended needs:
/// - a watchdog that restarts dsd-neo when it wedges (`DsdNeoWatchdog`),
/// - the talkgroup being heard, for AntennaHead's Now Playing,
/// - a per-system ledger of encrypted calls that locks talkgroups out of
///   later runs (`DsdNeoTalkgroupLedger`).
@MainActor
@Observable
final class DsdNeoScanner {
    enum State: Equatable {
        case idle
        case running
        case restarting(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The pipeline this scanner is feeding, while active.
    private(set) var pipelineID: Int64?
    private(set) var nowPlayingTalkgroup: Int?
    private(set) var nowPlayingText: String?
    private(set) var restartCount = 0
    private(set) var lastRestartReason: String?
    private(set) var lockedOutTalkgroups: Set<Int> = []
    /// This system's call history, overrides and sites while running — the
    /// dsd-neo Scanner tab's Talkgroups and Sites views read these live.
    private(set) var ledger = DsdNeoTalkgroupLedger()
    private(set) var overrides = DsdNeoTalkgroupOverrides()
    private(set) var sites = DsdNeoSiteTable()
    /// Talkgroup names from the list and the overrides.
    private(set) var names: [Int: String] = [:]
    /// Lockout overrides changed since dsd-neo started; they take effect
    /// when it next starts (dsd-neo reads its group list only at startup).
    private(set) var lockoutChangesPending = false

    var isActive: Bool {
        switch state {
        case .running, .restarting: return true
        case .idle, .failed: return false
        }
    }

    /// The attached terminal view's size; each (re)launch starts dsd-neo's
    /// pseudo-terminal at this size so its screens fit the view.
    @ObservationIgnored private var terminalSize: (columns: UInt16, rows: UInt16) = (120, 40)
    /// Recent terminal output, replayed when a terminal view attaches.
    @ObservationIgnored private(set) var terminalBacklog = Data()
    /// Live terminal output for an attached view.
    @ObservationIgnored var onTerminalOutput: ((Data) -> Void)?
    /// Called with "<name> (TG n)" whenever the talkgroup being heard changes.
    @ObservationIgnored var onNowPlaying: ((String) -> Void)?
    /// Called when the scanner gives up; the pipeline should be stopped.
    @ObservationIgnored var onFatal: ((String) -> Void)?
    /// Called with "BEE00-188" when dsd-neo reports the network, so the
    /// settings can remember it (see `DsdNeoScannerSettings.systemID`).
    @ObservationIgnored var onSystemIdentified: ((String) -> Void)?

    @ObservationIgnored private var process: PseudoTerminalProcess?
    @ObservationIgnored private var run: RunContext?
    @ObservationIgnored private var watchdog = DsdNeoWatchdog()
    @ObservationIgnored private var budget = DsdNeoRestartBudget()
    /// Restarts since dsd-neo last synced a P25 frame. Restarting can't fix a
    /// wedged RTL-SDR or a dead antenna, so after a few it gives up.
    @ObservationIgnored private var restartsWithoutSignal = 0
    static let maxRestartsWithoutSignal = 3
    @ObservationIgnored private var pendingGrant: (talkgroup: Int, encrypted: Bool)?
    @ObservationIgnored private var listNames: [Int: String] = [:]
    @ObservationIgnored private var sitesDirty = false
    /// Set once the network dsd-neo reports matches the settings' systemID.
    @ObservationIgnored private var networkConfirmed = false
    @ObservationIgnored private var eventLogOffset: UInt64 = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var stderrLog: FileHandle?
    /// Bumped on every launch; callbacks from an earlier dsd-neo are ignored.
    @ObservationIgnored private var generation = 0

    private struct RunContext {
        var settings: DsdNeoScannerSettings
        /// The pipeline stage's own arguments, passed after the settings' extras.
        var stageArguments: [String]
        var installation: DsdNeoInstallation
        var rtlIndex: UInt32
        var ownerAlive: () -> Bool
    }

    /// The settings dsd-neo is running with, while active.
    var runningSettings: DsdNeoScannerSettings? { run?.settings }

    static let terminalBacklogLimit = 256 * 1024
    static let stderrLogLimit: UInt64 = 50 * 1024 * 1024

    // MARK: Files

    /// ~/Library/Application Support/ControlBooth/dsd-neo
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ControlBooth/dsd-neo", isDirectory: true)
    }
    nonisolated static var eventLogURL: URL { directory.appendingPathComponent("events.log") }
    nonisolated static var stderrLogURL: URL { directory.appendingPathComponent("dsd-neo-stderr.log") }
    nonisolated static var effectiveGroupListURL: URL { directory.appendingPathComponent("groups-effective.csv") }

    // MARK: Start / stop

    /// Starts dsd-neo on USB device `rtlIndex` (already preflighted by the
    /// caller). `ownerAlive` reports whether the pipeline carrying the audio
    /// is still running; the scanner stops itself when it isn't.
    func start(settings: DsdNeoScannerSettings,
               stageArguments: [String] = [],
               installation: DsdNeoInstallation,
               rtlIndex: UInt32,
               pipelineID: Int64,
               ownerAlive: @escaping () -> Bool) throws {
        stop()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        self.pipelineID = pipelineID
        run = RunContext(settings: settings, stageArguments: stageArguments, installation: installation,
                         rtlIndex: rtlIndex, ownerAlive: ownerAlive)
        restartCount = 0
        lastRestartReason = nil
        budget = DsdNeoRestartBudget()
        restartsWithoutSignal = 0
        nowPlayingTalkgroup = nil
        nowPlayingText = nil
        terminalBacklog.removeAll()
        loadSystemState(key: settings.systemKey)
        do {
            try launch()
        } catch {
            run = nil
            self.pipelineID = nil
            state = .failed("\(error)")
            throw error
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Stops dsd-neo and waits for it to release the RTL-SDR.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        generation += 1
        process?.terminateAndWait()
        process = nil
        readEventLog()
        if sitesDirty, let run {
            sitesDirty = false
            DsdNeoSystemFiles.save(sites, .sites, key: run.settings.systemKey)
        }
        closeStderrLog()
        run = nil
        pipelineID = nil
        pendingGrant = nil
        if case .failed = state { return }
        state = .idle
    }

    /// Stops dsd-neo but keeps the pipeline's run, so `relaunch` can bring it
    /// back with new settings — e.g. on another RTL-SDR, once the caller has
    /// checked that one is free.
    func suspendForRelaunch() {
        guard run != nil else { return }
        generation += 1
        process?.terminateAndWait()
        process = nil
        readEventLog()
        closeStderrLog()
        pendingGrant = nil
        state = .restarting("applying new settings")
    }

    /// Relaunches dsd-neo, after `suspendForRelaunch`, with `settings` on USB
    /// device `rtlIndex`. The audio port stays the one the pipeline was
    /// started with. Failing here stops the pipeline (`onFatal`).
    func relaunch(settings: DsdNeoScannerSettings, rtlIndex: UInt32) {
        guard var run else { return }
        var settings = settings
        settings.audioPort = run.settings.audioPort
        run.settings = settings
        run.rtlIndex = rtlIndex
        self.run = run
        budget = DsdNeoRestartBudget()
        restartsWithoutSignal = 0
        restartCount = 0
        lastRestartReason = nil
        nowPlayingTalkgroup = nil
        nowPlayingText = nil
        loadSystemState(key: settings.systemKey)
        do {
            try launch()
        } catch {
            fail("could not relaunch dsd-neo: \(error)")
        }
    }

    /// Gives up: stops dsd-neo and has the owner stop the pipeline.
    func abandon(_ message: String) { fail(message) }

    /// Forgets which talkgroups carried encrypted calls on `settings`' system.
    /// Only while stopped: a running scanner would write its ledger back.
    static func forgetEncryptionHistory(for settings: DsdNeoScannerSettings) {
        try? FileManager.default.removeItem(at: DsdNeoSystemFiles.url(.talkgroups, key: settings.systemKey))
    }

    /// Talkgroups the saved ledger would lock out on `settings`' system.
    static func savedLockouts(for settings: DsdNeoScannerSettings) -> Set<Int> {
        let key = settings.systemKey
        let ledger = DsdNeoSystemFiles.load(DsdNeoTalkgroupLedger.self, .talkgroups, key: key) ?? .init()
        let overrides = DsdNeoSystemFiles.load(DsdNeoTalkgroupOverrides.self, .overrides, key: key) ?? .init()
        return ledger.lockedOut.subtracting(overrides.alwaysAllowed)
    }

    /// Saved state for `settings`' system, for the tab while not running.
    static func savedState(for settings: DsdNeoScannerSettings)
        -> (ledger: DsdNeoTalkgroupLedger, overrides: DsdNeoTalkgroupOverrides, sites: DsdNeoSiteTable)
    {
        let key = settings.systemKey
        return (DsdNeoSystemFiles.load(DsdNeoTalkgroupLedger.self, .talkgroups, key: key) ?? .init(),
                DsdNeoSystemFiles.load(DsdNeoTalkgroupOverrides.self, .overrides, key: key) ?? .init(),
                DsdNeoSystemFiles.load(DsdNeoSiteTable.self, .sites, key: key) ?? .init())
    }

    /// Saves overrides for `settings`' system. While running on that system
    /// the scanner takes them too: names at once (Now Playing included),
    /// lockout changes when dsd-neo next starts.
    func saveOverrides(_ newOverrides: DsdNeoTalkgroupOverrides, for settings: DsdNeoScannerSettings) {
        let key = run?.settings.systemKey ?? settings.systemKey
        DsdNeoSystemFiles.save(newOverrides, .overrides, key: key)
        guard run != nil else { return }
        let lockoutsChanged = newOverrides.lockedOut != overrides.lockedOut
            || newOverrides.alwaysAllowed != overrides.alwaysAllowed
        overrides = newOverrides
        if lockoutsChanged { lockoutChangesPending = true }
        rebuildNames()
        if let tg = nowPlayingTalkgroup {
            let text = displayText(for: tg)
            if text != nowPlayingText {
                nowPlayingText = text
                onNowPlaying?(text)
            }
        }
    }

    /// Keystrokes from an attached terminal view.
    func sendToTerminal(_ data: Data) { process?.write(data) }

    func resizeTerminal(columns: UInt16, rows: UInt16) {
        terminalSize = (columns, rows)
        process?.resize(columns: columns, rows: rows)
    }

    /// Kills dsd-neo processes a previous ControlBooth left running (a crash
    /// skips the normal stop), recognised by this app's event-log path in
    /// their arguments. They would otherwise keep the RTL-SDR busy.
    nonisolated static func killOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", "dsd-neo .*-J \(NSRegularExpression.escapedPattern(for: eventLogURL.path))"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    // MARK: Launch

    private func launch() throws {
        guard let run else { return }
        watchdog = DsdNeoWatchdog(now: Date())
        pendingGrant = nil

        // dsd-neo reads the group list once at startup, so each (re)launch
        // gets the source list plus the current lockouts.
        var groupListPath: String?
        var groups = DsdNeoGroupList()
        if !run.settings.groupListPath.isEmpty {
            let text = try String(contentsOfFile: (run.settings.groupListPath as NSString).expandingTildeInPath,
                                  encoding: .utf8)
            groups = DsdNeoGroupList(csv: text)
        }
        listNames = groups.displayNames
        rebuildNames()
        let encryptedLockouts = run.settings.encryptionLockout ? ledger.lockedOut : []
        let effective = groups.applying(overrides, encryptedLockouts: encryptedLockouts)
        lockedOutTalkgroups = encryptedLockouts.subtracting(overrides.alwaysAllowed).union(overrides.lockedOut)
        lockoutChangesPending = false
        if !effective.rows.isEmpty {
            try effective.csvText.write(to: Self.effectiveGroupListURL, atomically: true, encoding: .utf8)
            groupListPath = Self.effectiveGroupListURL.path
        }

        eventLogOffset = (try? FileManager.default.attributesOfItem(atPath: Self.eventLogURL.path)[.size] as? UInt64) ?? 0
        openStderrLog()

        generation += 1
        let current = generation
        let arguments = run.settings.arguments(rtlIndex: run.rtlIndex, groupListPath: groupListPath,
                                               eventLogPath: Self.eventLogURL.path) + run.stageArguments
        LogStore.shared.log(.info, source: "DsdNeoScanner",
                            "launching dsd-neo \(arguments.joined(separator: " "))")
        process = try PseudoTerminalProcess(
            executable: run.installation.executable,
            arguments: arguments,
            environment: run.installation.environment(),
            workingDirectory: Self.directory,
            columns: terminalSize.columns,
            rows: terminalSize.rows,
            onOutput: { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.terminalOutput(data)
                }
            },
            onStderrLine: { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.stderrLine(line)
                }
            },
            onExit: { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.processExited(status: status)
                }
            })
        state = .running
    }

    // MARK: Output handling

    private func terminalOutput(_ data: Data) {
        terminalBacklog.append(data)
        if terminalBacklog.count > Self.terminalBacklogLimit {
            terminalBacklog.removeFirst(terminalBacklog.count - Self.terminalBacklogLimit)
        }
        onTerminalOutput?(data)
    }

    private func stderrLine(_ line: String) {
        if let stderrLog {
            stderrLog.write(Data((line + "\n").utf8))
        }
        guard let event = DsdNeoLogParser.parse(line), process != nil else { return }
        switch event {
        case .grant(let tg, let encrypted):
            pendingGrant = (tg, encrypted)
        case .tunedToGrant:
            if let grant = pendingGrant, !grant.encrypted { reportTalkgroup(grant.talkgroup) }
        case .voiceUser(let tg, let encrypted):
            if !encrypted, tg > 0 { reportTalkgroup(tg) }
        case .p25Sync:
            restartsWithoutSignal = 0
            if !networkConfirmed, let network = DsdNeoLogParser.networkID(in: line) {
                identify(network)
            }
        case .homeSite(let system, let rfss, let site, let channel):
            sites.noteHome(system: system, rfss: rfss, site: site, channel: channel, at: Date())
            sitesDirty = true
        case .adjacentSite(let system, let rfss, let site, let channel):
            sites.noteAdjacent(system: system, rfss: rfss, site: site, channel: channel, at: Date())
            sitesDirty = true
        case .channelFrequency(let channel, let hertz):
            if sites.channelFrequencies[channel] != hertz {
                sites.noteFrequency(channel: channel, hertz: hertz)
                sitesDirty = true
            }
        case .selectedDevice(let index, let serial):
            if let run, !run.settings.rtlSerial.isEmpty, serial != run.settings.rtlSerial {
                fail("dsd-neo opened USB device #\(index) (serial \(serial)), not \(run.settings.rtlSerial).")
                return
            }
        default:
            break
        }
        if let reason = watchdog.observe(event) {
            restart(because: reason.description)
        }
    }

    private func reportTalkgroup(_ tg: Int) {
        guard tg != nowPlayingTalkgroup else { return }
        nowPlayingTalkgroup = tg
        let text = displayText(for: tg)
        nowPlayingText = text
        onNowPlaying?(text)
    }

    private func displayText(for tg: Int) -> String {
        names[tg].map { "\($0) (TG \(tg))" } ?? "TG \(tg)"
    }

    private func rebuildNames() {
        names = listNames.merging(overrides.names) { _, override in override }
    }

    /// dsd-neo reported the network. Remember it in the settings and move
    /// this system's state to the network's key (see `DsdNeoSystemFiles`).
    private func identify(_ network: DsdNeoNetworkID) {
        guard var run else { return }
        networkConfirmed = true
        guard run.settings.systemID != network.id else { return }
        let oldKey = run.settings.systemKey
        saveSystemState(key: oldKey)
        run.settings.systemID = network.id
        self.run = run
        let newKey = run.settings.systemKey
        DsdNeoSystemFiles.adopt(from: oldKey, to: newKey)
        loadSystemState(key: newKey)
        networkConfirmed = true
        LogStore.shared.log(.info, source: "DsdNeoScanner", "system identified as \(network.id)")
        onSystemIdentified?(network.id)
    }

    private func processExited(status: Int32) {
        guard run != nil else { return }
        let code = (status & 0x7f) == 0 ? "exited with status \((status >> 8) & 0xff)" : "was killed by signal \(status & 0x7f)"
        process = nil
        restart(because: "dsd-neo \(code)")
    }

    // MARK: Restart / failure

    private func restart(because reason: String) {
        guard run != nil else { return }
        guard restartsWithoutSignal < Self.maxRestartsWithoutSignal else {
            let device = run.map { $0.settings.rtlSerial.isEmpty ? "" : " (\($0.settings.rtlSerial))" } ?? ""
            fail("dsd-neo has had no P25 signal through \(Self.maxRestartsWithoutSignal) restarts. "
                 + "The RTL-SDR\(device) may have stopped delivering samples: unplug it, plug it back in, "
                 + "and start the scanner again. If that doesn't help, check the antenna and the control "
                 + "channel frequency.")
            return
        }
        guard budget.allowRestart(at: Date()) else {
            fail("dsd-neo kept failing (\(reason)); gave up after \(DsdNeoRestartBudget.maxRestarts) restarts "
                 + "in \(Int(DsdNeoRestartBudget.window)) seconds.")
            return
        }
        LogStore.shared.log(.warning, source: "DsdNeoScanner", "restarting dsd-neo: \(reason)")
        restartCount += 1
        restartsWithoutSignal += 1
        lastRestartReason = reason
        nowPlayingTalkgroup = nil
        nowPlayingText = nil
        state = .restarting(reason)
        generation += 1
        process?.terminateAndWait()
        process = nil
        readEventLog()
        closeStderrLog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.run != nil, case .restarting = self.state else { return }
                do {
                    try self.launch()
                } catch {
                    self.fail("could not restart dsd-neo: \(error)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        LogStore.shared.log(.error, source: "DsdNeoScanner", message)
        stop()
        state = .failed(message)
        onFatal?(message)
    }

    // MARK: Periodic work

    private func poll() {
        guard let run else { return }
        if !run.ownerAlive() {
            LogStore.shared.log(.info, source: "DsdNeoScanner", "pipeline stopped; stopping dsd-neo")
            stop()
            return
        }
        if case .running = state, let reason = watchdog.checkSilence(at: Date()) {
            restart(because: reason.description)
            return
        }
        readEventLog()
        if sitesDirty {
            sitesDirty = false
            DsdNeoSystemFiles.save(sites, .sites, key: run.settings.systemKey)
        }
        if let size = try? stderrLog?.offset(), size > Self.stderrLogLimit {
            try? stderrLog?.truncate(atOffset: 0)
        }
    }

    /// Reads calls dsd-neo has finished since the last read into the ledger.
    private func readEventLog() {
        guard let run, let handle = try? FileHandle(forReadingFrom: Self.eventLogURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < eventLogOffset { eventLogOffset = 0 }
        guard size > eventLogOffset else { return }
        try? handle.seek(toOffset: eventLogOffset)
        guard let data = try? handle.read(upToCount: Int(size - eventLogOffset)) else { return }
        // Only consume whole lines; a partial last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        eventLogOffset += UInt64(complete.count)

        let before = ledger.lockedOut
        for line in String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if let call = DsdNeoCallRecord(eventLogLine: String(line)) { ledger.record(call) }
        }
        DsdNeoSystemFiles.save(ledger, .talkgroups, key: run.settings.systemKey)
        for tg in ledger.lockedOut.subtracting(before).sorted() {
            LogStore.shared.log(.info, source: "DsdNeoScanner",
                                "talkgroup \(tg) \(names[tg].map { "(\($0)) " } ?? "")only carries encrypted calls; "
                                + "locking it out from the next dsd-neo start")
        }
    }

    private func loadSystemState(key: String) {
        ledger = DsdNeoSystemFiles.load(DsdNeoTalkgroupLedger.self, .talkgroups, key: key) ?? .init()
        overrides = DsdNeoSystemFiles.load(DsdNeoTalkgroupOverrides.self, .overrides, key: key) ?? .init()
        sites = DsdNeoSystemFiles.load(DsdNeoSiteTable.self, .sites, key: key) ?? .init()
        sitesDirty = false
        networkConfirmed = false
        rebuildNames()
    }

    private func saveSystemState(key: String) {
        DsdNeoSystemFiles.save(ledger, .talkgroups, key: key)
        DsdNeoSystemFiles.save(overrides, .overrides, key: key)
        DsdNeoSystemFiles.save(sites, .sites, key: key)
    }

    private func openStderrLog() {
        closeStderrLog()
        FileManager.default.createFile(atPath: Self.stderrLogURL.path, contents: nil)
        stderrLog = try? FileHandle(forWritingTo: Self.stderrLogURL)
    }

    private func closeStderrLog() {
        try? stderrLog?.close()
        stderrLog = nil
    }
}
