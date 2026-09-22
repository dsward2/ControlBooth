import Foundation
import Observation
import AirPlayReceiver
import SharedLogging

/// Thin wrapper owning the single AirPlayReceiverController instance,
/// applying ControlBooth's persisted AirPlaySettings to it. Unlike Pipeline
/// records (user-assembled, manually started chains), the AirPlay receiver is
/// a standalone always-advertising background service.
///
/// Splits two independently controlled states, matching `AirPlaySettings`:
///   `enabled`      — shairport-sync/sox are running at all (the receiver is
///                    advertising and decoding AirPlay audio).
///   `relayEnabled` — the decoded PCM is actually being forwarded to
///                    AntennaHead. Toggling this never restarts the receiver
///                    (see `AirPlayReceiverController.setRelayEnabled`), so an
///                    AirPlay client stays connected the whole time.
///
/// Both states can be driven from two places: locally (the Settings UI, via
/// `applySettings`) and remotely (AntennaHead's Remote Control page, via
/// `remoteEnableRelay`/`remoteDisableRelay`, reached through the `CBth`
/// AppleEvents in ScriptingCommands.swift). The local path announces itself
/// to AntennaHead before actually relaying (AntennaHead only opens its
/// PCMUDPReceiver bridge on that announcement — see AntennaHeadClient); the
/// remote path skips its own announce because AntennaHead already opened that
/// bridge itself before sending the AppleEvent that reaches here (mirrors
/// PipelineRunner's `start(_:)` vs `startAnnouncingToAntennaHead(_:)` split).
@MainActor
@Observable
final class AirPlayReceiverService {
    /// Name announced to AntennaHead over the AppleEvents control channel
    /// (see AntennaHeadClient) — fixed rather than derived from the AirPlay
    /// device name, since it identifies this standalone receiver's bridge to
    /// AntennaHead, not the AirPlay-visible speaker name. Deliberately
    /// doesn't repeat "ControlBooth": AntennaHead's own status text is always
    /// "ControlBooth: <this name>" (see SDRController.startControlBoothListening),
    /// so a value of "ControlBooth AirPlay Receiver" here would render as the
    /// redundant "ControlBooth: ControlBooth AirPlay Receiver". Must match
    /// AntennaHeadHTTPServer.controlBoothAirPlaySourceName exactly.
    private static let antennaHeadTaskName = "AirPlay Receiver"

    private struct AppliedIdentity: Equatable {
        let deviceName: String
        let host: String
        let port: UInt16
        let password: String?
    }

    private let controller: AirPlayReceiverController
    /// Set once from ControlBoothApp's `.onAppear`, like `AppDelegate.store`/
    /// `.runner` — needed so the remote (AntennaHead-initiated) entry points
    /// below can persist the settings they change.
    private var settingsStore: AirPlaySettingsStore?
    /// Pending async relay-start (the announce-then-setRelayEnabled dance);
    /// cancelled and replaced on each new attempt so rapid successive
    /// settings changes never race.
    private var startTask: Task<Void, Never>?
    /// Whether AntennaHead currently thinks this is (or is about to be) its
    /// active ControlBooth source — true after either the local path's own
    /// announce or a remote enable, so a later relay-off (local or remote)
    /// knows whether an announce-stop is owed.
    private var announcedToAntennaHead = false
    /// deviceName/host/port/password last actually applied to the running
    /// controller, so `applySettings` only restarts shairport-sync when one
    /// of those — not relayEnabled — actually changed.
    private var appliedIdentity: AppliedIdentity?

    var isRunning: Bool { controller.isRunning }
    var lastError: Error? { controller.lastError }
    var isReceivingAudio: Bool { controller.isReceivingAudio }
    var relayEnabled: Bool { controller.relayEnabled }
    var nowPlayingTrack: AirPlayReceiverController.NowPlayingTrack? { controller.nowPlayingTrack }

    init() {
        controller = AirPlayReceiverController(configuration: AirPlayReceiverService.makeConfiguration(from: .fallback()))
        controller.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
        controller.onNowPlayingChange = { [weak self] track in
            self?.pushNowPlaying(track)
        }
    }

    func setSettingsStore(_ store: AirPlaySettingsStore) {
        settingsStore = store
    }

    func stopAll() {
        stop()
    }

    /// The Settings UI's entry point (also called at launch with the loaded
    /// settings). Starts/stops the receiver based on `enabled`, then
    /// reconciles the relay state against what's currently applied.
    func applySettings(_ settings: AirPlaySettings) {
        guard settings.enabled else {
            stop()
            return
        }
        ensureRunning(settings: settings)
        reconcileRelay(desired: settings.relayEnabled, host: settings.destinationHost)
    }

    /// AntennaHead's Remote Control page picking the AirPlay receiver as its
    /// source: turns the receiver on if it was off and enables the relay, in
    /// one action. No self-announce — see the type doc comment. Persists so
    /// the Settings UI and future launches reflect it.
    func remoteEnableRelay() {
        guard let store = settingsStore else { return }
        var settings = store.settings
        settings.enabled = true
        settings.relayEnabled = true
        persist(settings, into: store)
        ensureRunning(settings: settings)
        announcedToAntennaHead = true
        controller.setRelayEnabled(true)
        pushNowPlaying(controller.nowPlayingTrack)
    }

    /// AntennaHead's Remote Control page stopping the relay — leaves the
    /// receiver itself running (stays "receiving but not sending"). No
    /// self-announce — see the type doc comment.
    func remoteDisableRelay() {
        guard let store = settingsStore else { return }
        var settings = store.settings
        settings.relayEnabled = false
        persist(settings, into: store)
        announcedToAntennaHead = false
        controller.setRelayEnabled(false)
    }

    private func persist(_ settings: AirPlaySettings, into store: AirPlaySettingsStore) {
        do {
            _ = try store.save(settings)
        } catch {
            LogStore.shared.log(.error, source: "AirPlayReceiverService", "couldn't persist remote AirPlay change: \(error)")
        }
    }

    /// Starts the controller, or restarts it if `deviceName`/host/port/
    /// password actually changed since the last time this ran — relay
    /// changes alone never reach this method (see `reconcileRelay`).
    ///
    /// `settings.relayEnabled` (the caller's *desired* end state, already
    /// updated before this is called — see `remoteEnableRelay`/
    /// `applySettings`) becomes the value a (re)started process launches
    /// with, so a cold start or identity-change restart lands in the right
    /// relay state immediately rather than depending on a follow-up live
    /// `setRelayEnabled` call landing after the async launch actually
    /// completes.
    private func ensureRunning(settings: AirPlaySettings) {
        let configuration = Self.makeConfiguration(from: settings)
        let identity = AppliedIdentity(deviceName: configuration.deviceName, host: configuration.udpHost,
                                       port: configuration.udpPort, password: configuration.password)
        if controller.isRunning {
            guard identity != appliedIdentity else { return }
            controller.updateConfiguration(configuration)
        } else {
            controller.updateConfiguration(configuration)
            controller.start()
        }
        appliedIdentity = identity
    }

    /// Diffs `desired` against `announcedToAntennaHead` — not
    /// `controller.relayEnabled`, which `ensureRunning` may already have set
    /// to `desired` via a fresh launch's baked-in `--relay` argument before
    /// AntennaHead has actually been told anything — and, only on a real
    /// transition, does the announce-then-relay-on (or
    /// relay-off-then-announce-stop) dance. Mirrors PipelineRunner's
    /// `startAnnouncingToAntennaHead`/`stopAnnouncingToAntennaHead`.
    private func reconcileRelay(desired: Bool, host: String) {
        guard desired != announcedToAntennaHead else { return }
        if desired {
            startRelay(host: host)
        } else {
            startTask?.cancel()
            startTask = nil
            controller.setRelayEnabled(false)
            announceStopIfNeeded()
        }
    }

    private func startRelay(host: String) {
        startTask?.cancel()
        let shouldAnnounce = Self.isLoopback(host)
        let taskName = Self.antennaHeadTaskName
        startTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if shouldAnnounce {
                // Off the main thread: the send blocks until AntennaHead replies.
                await Task.detached(priority: .userInitiated) {
                    AntennaHeadClient.announcePipelineStarting(taskName)
                }.value
                guard !Task.isCancelled else { return }
            }
            self.announcedToAntennaHead = shouldAnnounce
            self.controller.setRelayEnabled(true)
            // A track may already have been playing before relay turned on
            // (onNowPlayingChange won't fire again for it now that nothing's
            // changed) — push whatever's current so AntennaHead doesn't wait
            // for the *next* track change to show it.
            if shouldAnnounce {
                self.pushNowPlaying(self.controller.nowPlayingTrack)
            }
        }
    }

    private func stop() {
        startTask?.cancel()
        startTask = nil
        controller.stop()
        appliedIdentity = nil
        announceStopIfNeeded()
    }

    private func announceStopIfNeeded() {
        guard announcedToAntennaHead else { return }
        announcedToAntennaHead = false
        let taskName = Self.antennaHeadTaskName
        Task.detached(priority: .utility) {
            AntennaHeadClient.announcePipelineStopped(taskName)
        }
    }

    /// Pushes (or clears) the current track to AntennaHead's Now Playing
    /// display — only while it's actually listening to this source. No
    /// separate "clear" is needed when relay/the receiver stops entirely:
    /// `announceStopIfNeeded`'s 'Stop' event already makes AntennaHead switch
    /// away from this source altogether.
    private func pushNowPlaying(_ track: AirPlayReceiverController.NowPlayingTrack?) {
        guard announcedToAntennaHead else { return }
        let text = Self.displayText(for: track)
        Task.detached(priority: .utility) {
            AntennaHeadClient.announceNowPlaying(text)
        }
    }

    private static func displayText(for track: AirPlayReceiverController.NowPlayingTrack?) -> String {
        switch (track?.artist, track?.title) {
        case let (artist?, title?): return "\(artist) — \(title)"
        case let (artist?, nil): return artist
        case let (nil, title?): return title
        case (nil, nil): return ""
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func makeConfiguration(from settings: AirPlaySettings) -> AirPlayReceiverController.Configuration {
        AirPlayReceiverController.Configuration(
            deviceName: settings.deviceName,
            udpHost: settings.destinationHost,
            udpPort: UInt16(clamping: settings.destinationPort),
            relayEnabled: settings.relayEnabled
        )
    }
}
