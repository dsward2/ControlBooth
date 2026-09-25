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

    @ObservationIgnored private var process: PseudoTerminalProcess?
    @ObservationIgnored private var run: RunContext?
    @ObservationIgnored private var watchdog = DsdNeoWatchdog()
    @ObservationIgnored private var budget = DsdNeoRestartBudget()
    @ObservationIgnored private var pendingGrant: (talkgroup: Int, encrypted: Bool)?
    @ObservationIgnored private var ledger = DsdNeoTalkgroupLedger()
    @ObservationIgnored private var names: [Int: String] = [:]
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
    nonisolated static func ledgerURL(for settings: DsdNeoScannerSettings) -> URL {
        directory.appendingPathComponent("talkgroups-\(settings.systemKey).json")
    }

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
        nowPlayingTalkgroup = nil
        nowPlayingText = nil
        terminalBacklog.removeAll()
        loadLedger(for: settings)
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
        restartCount = 0
        lastRestartReason = nil
        nowPlayingTalkgroup = nil
        nowPlayingText = nil
        loadLedger(for: settings)
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
        try? FileManager.default.removeItem(at: ledgerURL(for: settings))
    }

    /// Talkgroups the saved ledger would lock out on `settings`' system.
    static func savedLockouts(for settings: DsdNeoScannerSettings) -> Set<Int> {
        guard let data = try? Data(contentsOf: ledgerURL(for: settings)),
              let ledger = try? JSONDecoder().decode(DsdNeoTalkgroupLedger.self, from: data) else { return [] }
        return ledger.lockedOut
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
        watchdog = DsdNeoWatchdog()
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
        names = groups.displayNames
        lockedOutTalkgroups = run.settings.encryptionLockout ? ledger.lockedOut : []
        if !run.settings.groupListPath.isEmpty || !lockedOutTalkgroups.isEmpty {
            let effective = groups.applyingLockout(lockedOutTalkgroups)
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
        let text = names[tg].map { "\($0) (TG \(tg))" } ?? "TG \(tg)"
        nowPlayingText = text
        onNowPlaying?(text)
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
        guard budget.allowRestart(at: Date()) else {
            fail("dsd-neo kept failing (\(reason)); gave up after \(DsdNeoRestartBudget.maxRestarts) restarts "
                 + "in \(Int(DsdNeoRestartBudget.window)) seconds.")
            return
        }
        LogStore.shared.log(.warning, source: "DsdNeoScanner", "restarting dsd-neo: \(reason)")
        restartCount += 1
        lastRestartReason = reason
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
        readEventLog()
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
        saveLedger(for: run.settings)
        for tg in ledger.lockedOut.subtracting(before).sorted() {
            LogStore.shared.log(.info, source: "DsdNeoScanner",
                                "talkgroup \(tg) \(names[tg].map { "(\($0)) " } ?? "")only carries encrypted calls; "
                                + "locking it out from the next dsd-neo start")
        }
    }

    private func loadLedger(for settings: DsdNeoScannerSettings) {
        if let data = try? Data(contentsOf: Self.ledgerURL(for: settings)),
           let saved = try? JSONDecoder().decode(DsdNeoTalkgroupLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = DsdNeoTalkgroupLedger()
        }
    }

    private func saveLedger(for settings: DsdNeoScannerSettings) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: Self.ledgerURL(for: settings), options: .atomic)
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
