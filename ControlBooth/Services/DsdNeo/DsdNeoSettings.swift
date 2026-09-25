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

/// How the scanner runs dsd-neo. One system (a trunked control channel) on
/// one RTL-SDR; the dsd-neo Scanner tab edits these. Stored as JSON in
/// ControlBooth's defaults under `dsdNeoScanner.settings` (by path —
/// `defaults write ~/Library/Preferences/com.dsward.ControlBooth …` — since a
/// leftover sandbox container can capture the plain bundle-ID form).
nonisolated struct DsdNeoScannerSettings: Codable, Equatable {
    /// EEPROM serial of the RTL-SDR (not its USB index, which can change).
    var rtlSerial: String = ""
    /// Control channel frequency in Hz.
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

    var isConfigured: Bool { controlChannelHz > 0 && !rtlSerial.isEmpty }

    /// A key naming the system, for per-system state such as the ledger.
    var systemKey: String { "cc-\(controlChannelHz)" }

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
    }

    /// dsd-neo's command line for USB device `rtlIndex`: P25 trunk following
    /// on the control channel, decoded audio to the local UDP port, the
    /// terminal UI on the pseudo-terminal, and the event log for call records.
    func arguments(rtlIndex: UInt32, groupListPath: String?, eventLogPath: String) -> [String] {
        let gain = gainDB == gainDB.rounded() ? String(Int(gainDB)) : String(gainDB)
        var args = [
            "-ft",
            "-i", "rtl:\(rtlIndex):\(Self.megahertz(controlChannelHz)):\(gain):\(ppm):\(bandwidthKHz):0:2",
            "-T",
        ]
        if let groupListPath { args += ["-G", groupListPath] }
        if encryptionLockout { args.append("--enc-lockout") }
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
