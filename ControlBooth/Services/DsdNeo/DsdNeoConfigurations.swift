import Foundation

/// One control channel a configuration can lock to, with a name for the site
/// that carries it.
nonisolated struct DsdNeoControlChannel: Codable, Equatable, Hashable, Identifiable {
    var hz: Int
    var label: String

    var id: Int { hz }

    /// "854.3625 MHz — Clearwell Road".
    var title: String {
        let frequency = DsdNeoConfiguration.megahertzText(hz) + " MHz"
        return label.isEmpty ? frequency : "\(frequency) — \(label)"
    }
}

/// A trunked system the scanner can follow (AWIN, CWIN, …): the control
/// channels it is known to use, which one is selected, its talkgroup list,
/// and the dongle to use. Choosing one fills the scanner's settings with
/// these; the rest of the settings (gain, bandwidth, follow mode, …) are
/// shared by every configuration.
nonisolated struct DsdNeoConfiguration: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// Control channels to choose from, in the order they are listed.
    var controlChannels: [DsdNeoControlChannel] = []
    /// The control channel in use (one of `controlChannels`, usually).
    var selectedControlChannelHz: Int = 0
    /// Talkgroup list (dsd-neo group CSV); empty = none.
    var groupListPath: String = ""
    /// EEPROM serial of the dongle this system uses; empty = leave the
    /// scanner's current dongle alone.
    var rtlSerial: String = ""
    /// The network the scanner last identified on this system ("BEE00-188").
    var systemID: String?

    /// "854.3625" — a frequency in MHz without trailing zeros.
    static func megahertzText(_ hertz: Int) -> String {
        String(DsdNeoScannerSettings.megahertz(hertz).dropLast())
    }

    /// The control channel `hz`, or nil when it isn't listed.
    func channel(at hz: Int) -> DsdNeoControlChannel? {
        controlChannels.first { $0.hz == hz }
    }

    /// The channels in `text`, one per line: a frequency in MHz, then an
    /// optional name ("854.3625 Clearwell Road"). Lines that don't start with
    /// a frequency are ignored; repeated frequencies keep the first.
    static func parseChannels(_ text: String) -> [DsdNeoControlChannel] {
        var channels: [DsdNeoControlChannel] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let first = parts.first,
                  let megahertz = Double(first.replacingOccurrences(of: "M", with: "")),
                  megahertz > 24, megahertz < 1_766 else { continue }
            let hz = Int((megahertz * 1_000_000).rounded())
            guard !channels.contains(where: { $0.hz == hz }) else { continue }
            let label = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            channels.append(DsdNeoControlChannel(hz: hz, label: label))
        }
        return channels
    }

    /// The inverse of `parseChannels`.
    var channelsText: String {
        controlChannels.map { channel in
            channel.label.isEmpty ? Self.megahertzText(channel.hz) : "\(Self.megahertzText(channel.hz)) \(channel.label)"
        }.joined(separator: "\n")
    }
}

/// The saved configurations and which one the scanner is set to. Stored as
/// JSON in ControlBooth's defaults next to the scanner settings, which stay
/// the single source of truth for what actually runs: choosing a
/// configuration copies its values into the settings, and saving the
/// settings copies them back.
nonisolated struct DsdNeoConfigurationSet: Codable, Equatable {
    var configurations: [DsdNeoConfiguration] = []
    var activeID: UUID?

    static let defaultsKey = "dsdNeoScanner.configurations"

    var active: DsdNeoConfiguration? {
        configurations.first { $0.id == activeID }
    }

    func configuration(id: UUID) -> DsdNeoConfiguration? {
        configurations.first { $0.id == id }
    }

    // MARK: Storage

    /// The saved set; on first use, the built-in systems with the one that
    /// matches `settings` (by control channel, then talkgroup list) active.
    static func load(settings: DsdNeoScannerSettings = .load(),
                     from defaults: UserDefaults = .standard) -> DsdNeoConfigurationSet {
        if let json = defaults.string(forKey: defaultsKey),
           let data = json.data(using: .utf8),
           let set = try? JSONDecoder().decode(DsdNeoConfigurationSet.self, from: data),
           !set.configurations.isEmpty {
            return set
        }
        return seeded(matching: settings)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }

    // MARK: Built-in systems

    /// Arkansas Wireless Information Network (WACN BEE00, system 188): the
    /// control channel the scanner has been following.
    static let awin = DsdNeoConfiguration(
        name: "AWIN",
        controlChannels: [DsdNeoControlChannel(hz: 853_187_500, label: "")],
        selectedControlChannelHz: 853_187_500,
        systemID: "BEE00-188")

    /// Conway 800 MHz (RadioReference sid 9054, WACN 927FA, system 00A):
    /// Site 001 Clearwell Road and Site 002 Collins Drive.
    static let cwin = DsdNeoConfiguration(
        name: "CWIN",
        controlChannels: [
            (854_362_500, "Clearwell Road"), (854_612_500, "Clearwell Road"),
            (856_962_500, "Clearwell Road"), (857_737_500, "Clearwell Road"),
            (858_237_500, "Clearwell Road"), (858_737_500, "Clearwell Road"),
            (859_237_500, "Clearwell Road"),
            (854_387_500, "Collins Drive"), (856_012_500, "Collins Drive"),
            (859_962_500, "Collins Drive"),
        ].map { DsdNeoControlChannel(hz: $0.0, label: $0.1) },
        selectedControlChannelHz: 854_362_500,
        systemID: "927FA-00A")

    /// AWIN and CWIN, with the one `settings` is on active; its talkgroup
    /// list and dongle go to that configuration. When `settings` matches
    /// neither, it becomes a third configuration.
    static func seeded(matching settings: DsdNeoScannerSettings) -> DsdNeoConfigurationSet {
        var set = DsdNeoConfigurationSet(configurations: [awin, cwin])
        guard settings.controlChannelHz > 0 else {
            set.activeID = set.configurations.first?.id
            return set
        }
        if let index = set.configurations.firstIndex(where: { $0.channel(at: settings.controlChannelHz) != nil }) {
            set.configurations[index].selectedControlChannelHz = settings.controlChannelHz
            set.configurations[index].groupListPath = settings.groupListPath
            set.configurations[index].rtlSerial = settings.rtlSerial
            set.activeID = set.configurations[index].id
        } else {
            let custom = DsdNeoConfiguration(
                name: "Current",
                controlChannels: [DsdNeoControlChannel(hz: settings.controlChannelHz, label: "")],
                selectedControlChannelHz: settings.controlChannelHz,
                groupListPath: settings.groupListPath, rtlSerial: settings.rtlSerial,
                systemID: settings.systemID)
            set.configurations.append(custom)
            set.activeID = custom.id
        }
        return set
    }

    // MARK: Choosing

    /// `settings` set to configuration `id` (and, when given, its control
    /// channel `hz`), and the set updated to match. Nil when `id` is unknown
    /// or `hz` isn't one of its control channels.
    func selecting(_ id: UUID, controlChannelHz hz: Int? = nil,
                   from settings: DsdNeoScannerSettings) -> (set: DsdNeoConfigurationSet, settings: DsdNeoScannerSettings)? {
        guard var configuration = configuration(id: id) else { return nil }
        if let hz {
            guard configuration.channel(at: hz) != nil else { return nil }
            configuration.selectedControlChannelHz = hz
        }
        var set = self
        set.activeID = id
        if let index = set.configurations.firstIndex(where: { $0.id == id }) {
            set.configurations[index] = configuration
        }
        var updated = settings
        let changed = updated.controlChannelHz != configuration.selectedControlChannelHz
        updated.controlChannelHz = configuration.selectedControlChannelHz
        updated.groupListPath = configuration.groupListPath
        if !configuration.rtlSerial.isEmpty { updated.rtlSerial = configuration.rtlSerial }
        // The network is the same on every channel of one system; it is
        // re-learned when the configuration changes.
        updated.systemID = configuration.systemID
        if !changed, settings.systemID != nil { updated.systemID = settings.systemID }
        return (set, updated)
    }

    /// Copies `settings` back into the active configuration (control
    /// channel, talkgroup list, dongle, network), adding the control channel
    /// to its list when it isn't there.
    mutating func record(_ settings: DsdNeoScannerSettings) {
        guard let index = configurations.firstIndex(where: { $0.id == activeID }) else { return }
        if settings.controlChannelHz > 0 {
            if configurations[index].channel(at: settings.controlChannelHz) == nil {
                configurations[index].controlChannels.append(
                    DsdNeoControlChannel(hz: settings.controlChannelHz, label: ""))
            }
            configurations[index].selectedControlChannelHz = settings.controlChannelHz
        }
        configurations[index].groupListPath = settings.groupListPath
        if !settings.rtlSerial.isEmpty { configurations[index].rtlSerial = settings.rtlSerial }
        if let systemID = settings.systemID, !systemID.isEmpty { configurations[index].systemID = systemID }
    }
}
