import Foundation
import Observation
import SharedLogging
import StationKit

/// AntennaHead Radio: ControlBooth's host for StationKit's station — Music.app
/// playlists through ControlBooth's AirPlay receiver into a mixer, with a
/// synthesized announcer (talk-overs, top-of-hour news, weather), sent to
/// AntennaHead as the source "AntennaHead Radio". The AntennaHead Radio tab
/// edits `settings` and starts/stops it.
///
/// While on air the station owns two shared things, and gives both back when
/// it stops: ControlBooth's AirPlay receiver (relayed to the station's music
/// port instead of its saved destination — see AirPlayReceiverService's
/// AntennaHead Radio section) and AntennaHead's ControlBooth receiver (any
/// pipeline sending there is stopped first).
@MainActor
@Observable
final class RadioStation {
    struct LogLine: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// Saved to ControlBooth's defaults on every change; a running station
    /// keeps the settings it started with until it's restarted.
    var settings: StationConfig {
        didSet { save() }
    }

    private(set) var director: Director?
    /// The settings the running station started with.
    private(set) var runningSettings: StationConfig?
    private(set) var lastError: String?
    /// Pipelines stopped to free AntennaHead's receiver at the last start.
    private(set) var stoppedPipelines: [String] = []
    private(set) var log: [LogLine] = []

    var isOnAir: Bool { director != nil }
    var needsRestart: Bool { runningSettings.map { $0 != settings } ?? false }

    @ObservationIgnored private weak var runner: PipelineRunner?
    @ObservationIgnored private weak var airPlay: AirPlayReceiverService?

    /// Where StationKit's log lines go (its `Log.handler` is process-wide).
    @ObservationIgnored private static weak var logSink: RadioStation?

    static let defaultsKey = "antennaHeadRadio.settings"
    private static let maxLogLines = 300

    init() {
        settings = Self.load()
    }

    func configure(runner: PipelineRunner, airPlay: AirPlayReceiverService) {
        self.runner = runner
        self.airPlay = airPlay
        Self.logSink = self
        Log.handler = { message in
            Task { @MainActor in RadioStation.logSink?.record(message) }
        }
    }

    // MARK: On air

    func start() {
        guard director == nil, let airPlay else { return }
        var config = settings
        config.helpersPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        config.speechSynthPath = nil
        stoppedPipelines = runner?.stopPipelines(sendingToLocalPort: Int(config.ports.antennaHead)) ?? []
        if !stoppedPipelines.isEmpty {
            record("stopped \(stoppedPipelines.joined(separator: ", ")) to take AntennaHead's input")
        }
        let director = Director(config: config,
                                options: .init(output: .udp(port: config.ports.antennaHead),
                                               announceToAntennaHead: true,
                                               controlMusic: true,
                                               musicPassword: musicPassword(for: config)),
                                relay: AirPlayStationRelay(service: airPlay))
        self.director = director
        runningSettings = settings
        lastError = nil
        Task { @MainActor in
            do {
                try await director.run()
            } catch {
                lastError = "\(error)"
            }
            if lastError == nil, let failure = director.failure { lastError = failure }
            self.director = nil
            runningSettings = nil
        }
    }

    func stop() {
        director?.stop()
    }

    func fire(_ segment: StationConfig.Segment) {
        director?.fire(segment)
    }

    /// The music source for `config` (defaults to the saved settings), with
    /// the remote Mac's password from the Keychain.
    func musicTarget(for config: StationConfig? = nil) -> MusicTarget {
        let config = config ?? settings
        return config.musicTarget(password: musicPassword(for: config))
    }

    private func musicPassword(for config: StationConfig) -> String? {
        guard let host = config.musicHost, !host.isEmpty, let user = config.musicHostUser else { return nil }
        return RemoteMusicCredentials.password(user: user, host: host)
    }

    /// App termination: no time for the orderly stop.
    func stopImmediately() {
        director?.stopImmediately()
    }

    /// The lines the next hour would use, without going on air.
    func preview() async -> String {
        var config = settings
        config.helpersPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        let director = Director(config: config,
                                options: .init(output: .udp(port: 0), announceToAntennaHead: false, controlMusic: false),
                                relay: nil)
        return await director.preview()
    }

    // MARK: Status

    /// The one-line status the tab and AntennaHead's ControlBooth page show.
    var statusText: String {
        switch director?.phase {
        case nil, .stopped?: return "Off the Air"
        case .starting?: return "Starting…"
        case .onAir?: return "On the Air"
        case .segment(let segment)?: return "On the Air: \(AntennaHeadRadioView.title(segment))"
        case .stopping?: return "Stopping…"
        }
    }

    /// What the "radio status" AppleEvent reports to AntennaHead.
    struct RemoteStatus: Codable, Equatable {
        /// "stopped", "starting", "onAir", "segment" or "stopping".
        var phase: String
        var statusText: String
        /// "Title — Artist" of the song playing.
        var nowPlaying: String?
        var lastError: String?
        /// The source name the station announces to AntennaHead under.
        var sourceName: String
    }

    func remoteStatus() -> RemoteStatus {
        let phase: String
        switch director?.phase {
        case nil, .stopped?: phase = "stopped"
        case .starting?: phase = "starting"
        case .onAir?: phase = "onAir"
        case .segment?: phase = "segment"
        case .stopping?: phase = "stopping"
        }
        return RemoteStatus(phase: phase, statusText: statusText, nowPlaying: director?.nowPlaying,
                            lastError: lastError,
                            sourceName: (runningSettings ?? settings).antennaHeadSourceName)
    }

    func remoteStatusJSON() -> String {
        guard let data = try? JSONEncoder().encode(remoteStatus()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Log

    private func record(_ message: String) {
        log.append(LogLine(date: Date(), text: message))
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
        LogStore.shared.log(.info, source: "AntennaHead Radio", message)
    }

    // MARK: Persistence (JSON in defaults, like the dsd-neo scanner's settings)

    private static func load(from defaults: UserDefaults = .standard) -> StationConfig {
        guard let json = defaults.string(forKey: defaultsKey),
              let config = try? StationConfig.merged(json: Data(json.utf8)) else {
            return .defaults
        }
        return config
    }

    private func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}

/// StationKit's `MusicRelay` over ControlBooth's own AirPlay receiver.
@MainActor
private final class AirPlayStationRelay: MusicRelay {
    private let service: AirPlayReceiverService

    init(service: AirPlayReceiverService) { self.service = service }

    func prepare(port: UInt16) async { await service.beginStationRelay(port: port) }
    func setRelay(_ on: Bool) { service.setStationRelay(on) }
    func finish() { service.endStationRelay() }
}
