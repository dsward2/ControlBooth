import Foundation

/// What the scanner needs from one line of dsd-neo's stderr. dsd-neo has no
/// machine-readable live status, so these match its human-readable trunking
/// diagnostics (verified against DSD-neo v2.8.1); anything else is `nil`.
nonisolated enum DsdNeoLogEvent: Equatable {
    /// A voice channel grant on the control channel. `encrypted` is the
    /// service-options encryption bit (0x40).
    case grant(talkgroup: Int, encrypted: Bool)
    /// The trunking state machine left the control channel for a grant.
    case tunedToGrant
    /// Voice-channel signalling naming the talkgroup on the air.
    case voiceUser(talkgroup: Int, encrypted: Bool)
    /// The tuner was retuned (control-channel hunt, grant, or return).
    case retune(hertz: Int)
    /// The P25 state machine lost the control channel.
    case controlChannelLost
    /// A P25 Phase 1 or Phase 2 frame synced — the receiver is decoding
    /// something. The scanner's sign of life.
    case p25Sync
    /// The RTL-SDR dsd-neo actually opened.
    case selectedDevice(index: Int, serial: String)
}

nonisolated enum DsdNeoLogParser {
    // "  SVC [44] CHAN [1449] Group [30147] Source [7438106]"
    private static let grant = try! NSRegularExpression(
        pattern: #"SVC \[([0-9A-Fa-f]{2})\].*?Group \[(\d+)\]"#)
    // " Group Voice Channel User - Group 3 Source 0"
    // " Encrypted Group Voice Channel User - Group 30147 Source 7438106"
    private static let voiceUser = try! NSRegularExpression(
        pattern: #"^\s*(Encrypted )?Group Voice Channel User - Group (\d+)"#)
    // "Retune applied: 851975000 Hz."
    private static let retune = try! NSRegularExpression(pattern: #"Retune applied: (\d+) Hz"#)
    // "NOTICE: Selected Device #1 with Serial Number: 00000180"
    private static let selected = try! NSRegularExpression(
        pattern: #"Selected Device #(\d+) with Serial Number: (\S+)"#)
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    static func parse(_ rawLine: String) -> DsdNeoLogEvent? {
        let line = stripANSI(rawLine)
        if line.contains("ON_CC -> TUNED") { return .tunedToGrant }
        // Each loss prints "[P25 SM] ON_CC -> HUNT (cc-lost)" then
        // "[P25 SM] cc-lost"; count only the second so one loss is one event.
        if line.trimmingCharacters(in: .whitespaces) == "[P25 SM] cc-lost" { return .controlChannelLost }
        if line.contains("Sync: +P25p1") || line.contains("Sync: +P25p2") { return .p25Sync }
        if let m = firstMatch(grant, line), let svc = Int(m[1], radix: 16), let tg = Int(m[2]) {
            return .grant(talkgroup: tg, encrypted: svc & 0x40 != 0)
        }
        if let m = firstMatch(voiceUser, line), let tg = Int(m[2]) {
            return .voiceUser(talkgroup: tg, encrypted: !m[1].isEmpty)
        }
        if let m = firstMatch(retune, line), let hz = Int(m[1]) {
            return .retune(hertz: hz)
        }
        if let m = firstMatch(selected, line), let index = Int(m[1]) {
            return .selectedDevice(index: index, serial: m[2])
        }
        return nil
    }

    static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return ansi.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// Capture groups of the first match (index 0 = whole match; an
    /// unmatched optional group is "").
    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

/// One finished call from dsd-neo's event log (`-J`), e.g.
/// `2026-09-25 12:56:42 P25p1 TGT: 00044720; SRC: 09770565; NAC: 18C;
/// NET_STS: BEE00:188:2.38; ENC; ALG: AA; KID: AA85; Group; TName: …; Mode: A;`
/// dsd-neo writes each line when the call ends.
nonisolated struct DsdNeoCallRecord: Equatable {
    var talkgroup: Int
    var source: Int
    var encrypted: Bool
    var isGroupCall: Bool

    private static let target = try! NSRegularExpression(pattern: #"\bTGT: (\d+);"#)
    private static let sourceID = try! NSRegularExpression(pattern: #"\bSRC: (\d+);"#)

    init(talkgroup: Int, source: Int, encrypted: Bool, isGroupCall: Bool) {
        self.talkgroup = talkgroup
        self.source = source
        self.encrypted = encrypted
        self.isGroupCall = isGroupCall
    }

    /// nil for the header lines and anything that isn't a call.
    init?(eventLogLine line: String) {
        let range = NSRange(line.startIndex..., in: line)
        guard let tgMatch = Self.target.firstMatch(in: line, range: range),
              let tgRange = Range(tgMatch.range(at: 1), in: line),
              let tg = Int(line[tgRange]) else { return nil }
        var src = 0
        if let m = Self.sourceID.firstMatch(in: line, range: range),
           let r = Range(m.range(at: 1), in: line) {
            src = Int(line[r]) ?? 0
        }
        let fields = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        self.init(talkgroup: tg, source: src,
                  encrypted: fields.contains("ENC"),
                  isGroupCall: fields.contains("Group"))
    }
}
