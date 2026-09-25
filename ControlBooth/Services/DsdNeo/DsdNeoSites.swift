import Foundation

/// The sites of one P25 system, learned from the control channel: its own
/// RFSS Status Broadcast (the home site) and Adjacent Site Status Broadcasts
/// (neighbours), with each site's control channel frequency from dsd-neo's
/// channel map.
///
/// Corrupted broadcasts get through often enough to matter (seen live:
/// neighbours with another system's ID, or channel F499 among 171 sightings
/// of 0549), so a neighbour is listed only when it belongs to the home
/// system and has been heard `minimumSightings` times, and each site's
/// channel is the one reported most often.
nonisolated struct DsdNeoSiteTable: Codable, Equatable {
    struct Site: Codable, Equatable, Identifiable {
        var rfss: Int
        var site: Int
        /// Control channel number → times reported.
        var channelSightings: [Int: Int] = [:]
        var lastSeen: Date
        /// The site whose control channel is being monitored.
        var isHome = false

        var id: String { "\(rfss)-\(site)" }
        var sightings: Int { channelSightings.values.reduce(0, +) }
        var channel: Int? {
            channelSightings.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }
    }

    static let minimumSightings = 3

    /// The system ID (hex, e.g. "188") of the home site, once known.
    var system: String?
    var sites: [String: Site] = [:]
    /// Channel number → frequency in Hz, from dsd-neo's channel map.
    var channelFrequencies: [Int: Int] = [:]

    mutating func noteHome(system: String, rfss: Int, site: Int, channel: Int, at now: Date) {
        if self.system != system {
            // A different system: nothing learned so far applies.
            if self.system != nil { sites.removeAll() }
            self.system = system
        }
        for key in sites.keys where sites[key]?.isHome == true && key != "\(rfss)-\(site)" {
            sites[key]?.isHome = false
        }
        note(rfss: rfss, site: site, channel: channel, at: now)
        sites["\(rfss)-\(site)"]?.isHome = true
    }

    mutating func noteAdjacent(system: String, rfss: Int, site: Int, channel: Int, at now: Date) {
        guard let home = self.system, home == system else { return }
        note(rfss: rfss, site: site, channel: channel, at: now)
    }

    mutating func noteFrequency(channel: Int, hertz: Int) {
        guard DsdNeoWatchdog.tunableHertz.contains(hertz) else { return }
        channelFrequencies[channel] = hertz
    }

    private mutating func note(rfss: Int, site: Int, channel: Int, at now: Date) {
        let key = "\(rfss)-\(site)"
        var entry = sites[key] ?? Site(rfss: rfss, site: site, lastSeen: now)
        entry.channelSightings[channel, default: 0] += 1
        entry.lastSeen = now
        sites[key] = entry
    }

    func frequency(of site: Site) -> Int? {
        site.channel.flatMap { channelFrequencies[$0] }
    }

    /// Sites worth showing, home first, then by RFSS and site number.
    var listedSites: [Site] {
        sites.values
            .filter { $0.isHome || $0.sightings >= Self.minimumSightings }
            .sorted { a, b in
                if a.isHome != b.isHome { return a.isHome }
                return (a.rfss, a.site) < (b.rfss, b.site)
            }
    }
}

/// Per-talkgroup choices the user makes in the dsd-neo Scanner tab, layered
/// over the imported talkgroup list: names (for talkgroups the list lacks or
/// names it gets wrong), manual lockouts, and talkgroups never to lock out
/// automatically even when they carry only encrypted calls.
nonisolated struct DsdNeoTalkgroupOverrides: Codable, Equatable {
    var names: [Int: String] = [:]
    var lockedOut: Set<Int> = []
    var alwaysAllowed: Set<Int> = []

    enum Policy: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case allow = "Always Allow"
        case lockOut = "Locked Out"
        var id: String { rawValue }
    }

    func policy(for tg: Int) -> Policy {
        if lockedOut.contains(tg) { return .lockOut }
        if alwaysAllowed.contains(tg) { return .allow }
        return .automatic
    }

    mutating func setPolicy(_ policy: Policy, for tg: Int) {
        lockedOut.remove(tg)
        alwaysAllowed.remove(tg)
        switch policy {
        case .automatic: break
        case .allow: alwaysAllowed.insert(tg)
        case .lockOut: lockedOut.insert(tg)
        }
    }

    mutating func setName(_ name: String, for tg: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[tg] = trimmed.isEmpty ? nil : trimmed
    }
}

/// Where a system's learned state lives, and moving it when the system's
/// identity becomes known.
///
/// State is keyed by the network identity (WACN and system ID, e.g.
/// "sys-BEE00-188") once dsd-neo has reported it, so every site of a system
/// shares one talkgroup history. Before that it is keyed by the control
/// channel ("cc-853187500"), and moves to the identity key when learned.
nonisolated enum DsdNeoSystemFiles {
    enum Kind: String, CaseIterable {
        case talkgroups, overrides, sites
    }

    static func url(_ kind: Kind, key: String) -> URL {
        DsdNeoScanner.directory.appendingPathComponent("\(kind.rawValue)-\(key).json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ kind: Kind, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(kind, key: key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ kind: Kind, key: String) {
        try? FileManager.default.createDirectory(at: DsdNeoScanner.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(kind, key: key), options: .atomic)
    }

    /// Moves state saved under a control-channel key to the system's
    /// identity key, unless the identity already has its own. Never moves
    /// one system's state onto another's.
    static func adopt(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, oldKey.hasPrefix("cc-") else { return }
        let fm = FileManager.default
        for kind in Kind.allCases {
            let from = url(kind, key: oldKey), to = url(kind, key: newKey)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}
