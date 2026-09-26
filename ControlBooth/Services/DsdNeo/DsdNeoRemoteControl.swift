import Foundation

/// The dsd-neo Scanner controls AntennaHead's ControlBooth Remote Control page
/// uses, over the "dsd-neo …" AppleEvents in ControlBooth.sdef: status, which
/// calls to follow, skipping the call being heard, and talkgroup lockouts.
///
/// Mode and lockout changes are saved and, while the scanner runs, applied at
/// once by relaunching dsd-neo (it reads its options and group list only at
/// startup); the pipeline keeps playing through the few seconds that takes.
@MainActor
enum DsdNeoRemoteControl {
    /// Posted after a remote change to the saved settings, so an open dsd-neo
    /// Scanner tab picks them up instead of saving over them.
    static let settingsChangedNotification = Notification.Name("DsdNeoRemoteControl.settingsChanged")

    enum RemoteError: Error, CustomStringConvertible {
        case badArgument(String)
        var description: String {
            switch self {
            case .badArgument(let why): return why
            }
        }
    }

    // MARK: Status

    struct Talkgroup: Codable, Equatable {
        var talkgroup: Int
        var name: String
    }

    struct Status: Codable, Equatable {
        var installed: Bool
        var configured: Bool
        /// "idle", "running", "restarting" or "failed".
        var state: String
        /// Why it is restarting or failed.
        var message: String?
        /// Pipelines that run the scanner (normally just "dsd-neo Scanner").
        var pipelineNames: [String]
        /// The scanner pipeline that is running, if any.
        var activePipeline: String?
        var mode: String
        var holdTalkgroup: Int?
        /// The talkgroup heard most recently this run.
        var talkgroup: Int?
        var talkgroupText: String?
        var systemID: String?
        var controlChannelHz: Int
        /// Locked out by hand (the blacklist).
        var lockedOut: [Talkgroup]
        /// Locked out automatically for carrying only encrypted calls.
        var encryptedLockedOut: [Talkgroup]
        var alwaysAllowed: [Talkgroup]
        /// Heard recently, newest first, for picking a talkgroup to hold or lock out.
        var recent: [Talkgroup]
    }

    static let recentLimit = 20

    static func status(store: PipelineStore, runner: PipelineRunner) -> Status {
        let scanner = runner.dsdNeoScanner
        let settings = scanner.runningSettings ?? DsdNeoScannerSettings.load()
        let saved = DsdNeoScanner.savedState(for: settings)
        let ledger = scanner.isActive ? scanner.ledger : saved.ledger
        let overrides = scanner.isActive ? scanner.overrides : saved.overrides
        let names = talkgroupNames(settings: settings, overrides: overrides)
        func entries(_ ids: some Sequence<Int>) -> [Talkgroup] {
            ids.sorted().map { Talkgroup(talkgroup: $0, name: names[$0] ?? "") }
        }

        let state: String
        var message: String?
        switch scanner.state {
        case .idle: state = "idle"
        case .running: state = "running"
        case .restarting(let why): state = "restarting"; message = why
        case .failed(let why): state = "failed"; message = why
        }
        let pipelines = store.pipelines.filter { $0.stages.first.map(PipelineRunner.isDsdNeoScannerStage) == true }
        let active = pipelines.first { runner.isRunning($0) && $0.id == scanner.pipelineID }
        let encrypted = settings.encryptionLockout
            ? ledger.lockedOut.subtracting(overrides.alwaysAllowed).subtracting(overrides.lockedOut) : []
        let recent = ledger.counts
            .filter { $0.value.lastHeard != nil && $0.value.clear > 0 }
            .sorted { ($0.value.lastHeard ?? .distantPast) > ($1.value.lastHeard ?? .distantPast) }
            .prefix(recentLimit)
            .map { Talkgroup(talkgroup: $0.key, name: names[$0.key] ?? "") }

        return Status(installed: DsdNeoInstallation.detect() != nil,
                      configured: settings.isConfigured,
                      state: state, message: message,
                      pipelineNames: pipelines.map(\.name),
                      activePipeline: active?.name,
                      mode: settings.effectiveFollowMode.rawValue,
                      holdTalkgroup: settings.effectiveFollowMode == .hold ? settings.holdTalkgroup : nil,
                      talkgroup: scanner.isActive ? scanner.nowPlayingTalkgroup : nil,
                      talkgroupText: scanner.isActive ? scanner.nowPlayingText : nil,
                      systemID: settings.systemID,
                      controlChannelHz: settings.controlChannelHz,
                      lockedOut: entries(overrides.lockedOut),
                      encryptedLockedOut: entries(encrypted),
                      alwaysAllowed: entries(overrides.alwaysAllowed),
                      recent: Array(recent))
    }

    static func statusJSON(store: PipelineStore, runner: PipelineRunner) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(status(store: store, runner: runner)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Names from the settings' talkgroup list, with the overrides' names on top.
    private static func talkgroupNames(settings: DsdNeoScannerSettings,
                                       overrides: DsdNeoTalkgroupOverrides) -> [Int: String] {
        var names: [Int: String] = [:]
        let path = (settings.groupListPath as NSString).expandingTildeInPath
        if !path.isEmpty, let text = DsdNeoScannerView.readText(URL(fileURLWithPath: path)) {
            names = DsdNeoGroupList(csv: text).displayNames
        }
        return names.merging(overrides.names) { _, override in override }
    }

    // MARK: Commands

    /// Sets which calls to follow. `holdTalkgroup` is required for `.hold`.
    static func setMode(_ mode: DsdNeoFollowMode, holdTalkgroup: Int?, runner: PipelineRunner) throws {
        var settings = DsdNeoScannerSettings.load()
        if mode == .hold {
            guard let tg = holdTalkgroup, tg > 0 else {
                throw RemoteError.badArgument("Hold Talkgroup needs a talkgroup number.")
            }
            settings.holdTalkgroup = tg
        }
        settings.followMode = mode
        try runner.applyDsdNeoSettings(settings)
        NotificationCenter.default.post(name: settingsChangedNotification, object: nil)
    }

    /// Leaves the call being heard.
    static func skipCall(runner: PipelineRunner) {
        runner.dsdNeoScanner.skipCall()
    }

    /// Sets a talkgroup's lockout policy and, while running, relaunches
    /// dsd-neo so it takes effect now.
    static func setPolicy(_ policy: DsdNeoTalkgroupOverrides.Policy, for tg: Int, runner: PipelineRunner) throws {
        guard tg > 0 else { throw RemoteError.badArgument("A talkgroup number is required.") }
        let scanner = runner.dsdNeoScanner
        let settings = scanner.runningSettings ?? DsdNeoScannerSettings.load()
        var overrides = scanner.isActive ? scanner.overrides : DsdNeoScanner.savedState(for: settings).overrides
        guard overrides.policy(for: tg) != policy else { return }
        overrides.setPolicy(policy, for: tg)
        scanner.saveOverrides(overrides, for: settings)
        if scanner.lockoutChangesPending {
            try runner.applyDsdNeoSettings(DsdNeoScannerSettings.load())
        }
        NotificationCenter.default.post(name: settingsChangedNotification, object: nil)
    }
}
