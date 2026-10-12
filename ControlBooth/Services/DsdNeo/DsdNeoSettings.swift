import Foundation

/// A dsd-neo install in its standard portable layout
/// (`/Applications/dsd-neo-macos/{bin/dsd-neo, lib/, share/terminfo/}`).
nonisolated struct DsdNeoInstallation: Equatable {
    static let standardRoot = URL(fileURLWithPath: "/Applications/dsd-neo-macos", isDirectory: true)

    let root: URL
    var executable: URL { root.appendingPathComponent("bin/dsd-neo") }
    var libraryDirectory: URL { root.appendingPathComponent("lib", isDirectory: true) }
    var terminfoDirectory: URL { root.appendingPathComponent("share/terminfo", isDirectory: true) }

    /// The install at `root`, or nil when there is no executable there.
    static func detect(at root: URL = standardRoot) -> DsdNeoInstallation? {
        let install = DsdNeoInstallation(root: root)
        guard FileManager.default.isExecutableFile(atPath: install.executable.path) else { return nil }
        return install
    }

    /// True while macOS's download quarantine flag is still on the binary:
    /// Gatekeeper then kills the ad-hoc-signed dsd-neo on launch (exit 137)
    /// before it prints anything.
    var isQuarantined: Bool {
        getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// The command that clears the flag, for the user to run themselves.
    var quarantineFixCommand: String {
        "xattr -dr com.apple.quarantine \(root.path)"
    }

    /// Environment the portable build's own `dsd-neo.sh` launcher sets up:
    /// its bundled dylibs and ncurses terminal descriptions.
    func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryDirectory.path
        env["TERMINFO_DIRS"] = [terminfoDirectory.path, "/usr/share/terminfo"].joined(separator: ":")
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }
}

/// Which calls the scanner follows on its system.
nonisolated enum DsdNeoFollowMode: String, Codable, CaseIterable, Identifiable {
    /// Every talkgroup that isn't locked out.
    case scanAll = "scan"
    /// Only talkgroups marked Always Allow (dsd-neo's `-W` allow-list mode).
    case allowListOnly = "allowList"
    /// Only `holdTalkgroup` (dsd-neo's `-I`).
    case hold = "hold"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanAll: return "Scan All"
        case .allowListOnly: return "Always Allow Only"
        case .hold: return "Hold Talkgroup"
        }
    }
}

/// What kind of system the scanner listens to. dsd-neo decodes both, but they
/// are followed differently, so the scanner's arguments, log parsing and
/// watchdog depend on it.
nonisolated enum DsdNeoSystemType: String, Codable, CaseIterable, Identifiable {
    /// A trunked P25 system: dsd-neo follows grants from a control channel
    /// (`-ft`) to voice channels.
    case p25Trunked = "p25"
    /// A conventional (non-trunked) DMR channel: dsd-neo sits on one
    /// frequency and decodes whatever is keyed up on it (`-fs`).
    case dmrConventional = "dmr"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p25Trunked: return "P25 Trunked"
        case .dmrConventional: return "DMR Conventional"
        }
    }

    /// What the tuned frequency is called in the UI.
    var channelTitle: String {
        switch self {
        case .p25Trunked: return "Control Channel"
        case .dmrConventional: return "Channel"
        }
    }

    /// Only P25 trunking has sites, call grants to follow or a hold mode.
    var isTrunked: Bool { self == .p25Trunked }

    /// A trunked control channel transmits continuously, so a long silence
    /// means dsd-neo isn't receiving. A conventional channel is silent
    /// whenever nobody is talking, so silence says nothing.
    var silenceIndicatesFailure: Bool { isTrunked }

    /// "P25" or "DMR", for messages.
    var protocolName: String {
        switch self {
        case .p25Trunked: return "P25"
        case .dmrConventional: return "DMR"
        }
    }
}

/// How the scanner runs dsd-neo. One system (a trunked control channel) on
/// one RTL-SDR; the dsd-neo Scanner tab edits these. Stored as JSON in
/// ControlBooth's defaults under `dsdNeoScanner.settings` (by path —
/// `defaults write ~/Library/Preferences/com.dsward.ControlBooth …` — since a
/// leftover sandbox container can capture the plain bundle-ID form).
nonisolated struct DsdNeoScannerSettings: Codable, Equatable {
    /// EEPROM serial of the RTL-SDR (not its USB index, which can change).
    var rtlSerial: String = ""
    /// The frequency in Hz: a trunked system's control channel, or a
    /// conventional system's channel.
    var controlChannelHz: Int = 0
    /// Tuner gain in dB; 0 = automatic.
    var gainDB: Double = 48
    /// Frequency correction in ppm.
    var ppm: Int = 0
    /// dsd-neo's DSP bandwidth in kHz.
    var bandwidthKHz: Int = 24
    /// Talkgroup names and allow/block list (dsd-neo group CSV); empty = none.
    var groupListPath: String = ""
    /// Skip encrypted calls this session and learn which talkgroups to lock
    /// out permanently (see `DsdNeoTalkgroupLedger`).
    var encryptionLockout: Bool = true
    /// Local UDP port dsd-neo sends decoded audio to.
    var audioPort: Int = 23480
    /// Anything else to pass to dsd-neo, one argument per element.
    var extraArguments: [String] = []
    /// The network dsd-neo last reported on this control channel
    /// ("BEE00-188"), filled in by the scanner. Optional so settings saved
    /// before it existed still decode.
    var systemID: String?
    /// Which calls to follow; nil (settings saved before this existed) is
    /// Scan All.
    var followMode: DsdNeoFollowMode?
    /// The talkgroup Hold Talkgroup mode stays on.
    var holdTalkgroup: Int?
    /// What kind of system this is; nil (settings saved before DMR support
    /// existed) is P25 Trunked.
    var systemType: DsdNeoSystemType?

    var effectiveSystemType: DsdNeoSystemType { systemType ?? .p25Trunked }

    var effectiveFollowMode: DsdNeoFollowMode {
        // Only a trunked system has calls to follow.
        guard effectiveSystemType.isTrunked else { return .scanAll }
        let mode = followMode ?? .scanAll
        if mode == .hold, (holdTalkgroup ?? 0) <= 0 { return .scanAll }
        return mode
    }

    var isConfigured: Bool { controlChannelHz > 0 && !rtlSerial.isEmpty }

    /// A key naming the system, for per-system state (talkgroup history,
    /// overrides, sites): the network identity once known, so every site of
    /// a system shares it; the control channel until then.
    var systemKey: String {
        if let systemID, !systemID.isEmpty { return "sys-\(systemID)" }
        // P25 keeps the old "cc-" key, so existing per-system state still matches.
        return effectiveSystemType.isTrunked ? "cc-\(controlChannelHz)" : "dmr-\(controlChannelHz)"
    }

    static let defaultsKey = "dsdNeoScanner.settings"

    static func load(from defaults: UserDefaults = .standard) -> DsdNeoScannerSettings {
        guard let json = defaults.string(forKey: defaultsKey),
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(DsdNeoScannerSettings.self, from: data) else {
            return DsdNeoScannerSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
        // Keep the active configuration (AWIN, CWIN, …) in step with what
        // the scanner is now set to.
        var configurations = DsdNeoConfigurationSet.load(settings: self, from: defaults)
        configurations.record(self)
        configurations.save(to: defaults)
    }

    /// dsd-neo's command line for USB device `rtlIndex`: P25 trunk following
    /// on the control channel (or, for a conventional DMR system, decoding
    /// the one channel), decoded audio to the local UDP port, the terminal UI
    /// on the pseudo-terminal, and the event log for call records.
    func arguments(rtlIndex: UInt32, groupListPath: String?, eventLogPath: String) -> [String] {
        let gain = gainDB == gainDB.rounded() ? String(Int(gainDB)) : String(gainDB)
        let type = effectiveSystemType
        var args = [
            type.isTrunked ? "-ft" : "-fs",
            "-i", "rtl:\(rtlIndex):\(Self.megahertz(controlChannelHz)):\(gain):\(ppm):\(bandwidthKHz):0:2",
        ]
        if type.isTrunked { args.append("-T") }
        if let groupListPath { args += ["-G", groupListPath] }
        if encryptionLockout { args.append("--enc-lockout") }
        // Following calls is trunking: a conventional channel has nothing to
        // follow, so its follow mode is ignored.
        if type.isTrunked {
            switch effectiveFollowMode {
            case .scanAll: break
            case .allowListOnly: args.append("-W")
            case .hold: args += ["-I", String(holdTalkgroup ?? 0)]
            }
        }
        args += [
            "-o", "udp:127.0.0.1:\(audioPort)",
            "-J", eventLogPath,
            "--frontend", "terminal",
        ]
        return args + extraArguments
    }

    /// "853.1875M" — the form dsd-neo's own examples use for rtl: frequencies.
    static func megahertz(_ hertz: Int) -> String {
        var text = String(format: "%.6f", Double(hertz) / 1_000_000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "M"
    }
}
