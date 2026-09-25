import Foundation

/// A dsd-neo group list CSV (`-G`): a header line, then `id,mode,name[,…]`
/// rows. Kept as raw lines so rows round-trip unchanged apart from the mode
/// column the lockout rewrites.
nonisolated struct DsdNeoGroupList: Equatable {
    var header: String
    var rows: [Row]

    struct Row: Equatable {
        var talkgroup: Int
        var fields: [String]      // every column, fields[1] is the mode
        var name: String { fields.count > 2 ? fields[2] : "" }
        var mode: String { fields.count > 1 ? fields[1] : "" }
    }

    static let defaultHeader = "DEC,Mode,Name,Tag"

    init(header: String = defaultHeader, rows: [Row] = []) {
        self.header = header
        self.rows = rows
    }

    /// Parses CSV text. Lines whose first field isn't a talkgroup number
    /// (blank lines, comments, ranges) are dropped; ranges are rare and only
    /// matter to dsd-neo's own policy, not to naming or lockout.
    init(csv text: String) {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0) }
        let header = lines.isEmpty ? Self.defaultHeader : lines.removeFirst()
        var rows: [Row] = []
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, let tg = Int(fields[0]) else { continue }
            rows.append(Row(talkgroup: tg, fields: fields))
        }
        self.init(header: header.isEmpty ? Self.defaultHeader : header, rows: rows)
    }

    /// Display names by talkgroup. When the header has a column named
    /// FullName (as `tsv2group.py`'s output does), it wins over the short
    /// Name column dsd-neo itself shows.
    var displayNames: [Int: String] {
        let headerFields = header.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let fullIndex = headerFields.firstIndex { $0.hasPrefix("fullname") || $0.hasPrefix("full name") }
        var names: [Int: String] = [:]
        for row in rows {
            var name = row.name
            if let fullIndex, fullIndex < row.fields.count,
               !row.fields[fullIndex].isEmpty, !row.fields[fullIndex].hasPrefix("(") {
                name = row.fields[fullIndex].replacingOccurrences(of: "; ", with: ", ")
            }
            if names[row.talkgroup] == nil { names[row.talkgroup] = name }
        }
        return names
    }

    /// The list dsd-neo is given: every row as-is, except talkgroups in
    /// `lockedOut` get mode `DE` (dsd-neo's "digital encrypted" lockout), and
    /// locked-out talkgroups the list doesn't have get a row of their own.
    func applyingLockout(_ lockedOut: Set<Int>) -> DsdNeoGroupList {
        applying(DsdNeoTalkgroupOverrides(), encryptedLockouts: lockedOut)
    }

    /// The list dsd-neo is given, with the user's overrides and the
    /// automatic encryption lockouts applied. Precedence: Always Allow
    /// (mode A) beats a manual lockout (B) beats an encryption lockout (DE)
    /// beats the list's own mode. Override names replace the list's names.
    /// Talkgroups the list lacks get rows of their own when named or locked.
    func applying(_ overrides: DsdNeoTalkgroupOverrides, encryptedLockouts: Set<Int>) -> DsdNeoGroupList {
        let encrypted = encryptedLockouts.subtracting(overrides.alwaysAllowed)
        let headerFields = header.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let fullIndex = headerFields.firstIndex { $0.hasPrefix("fullname") || $0.hasPrefix("full name") }

        func mode(for tg: Int, listed: String?) -> String? {
            if overrides.alwaysAllowed.contains(tg) { return "A" }
            if overrides.lockedOut.contains(tg) { return "B" }
            if encrypted.contains(tg) { return "DE" }
            return listed
        }
        func csvSafe(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ";") }
        func shortName(_ s: String) -> String {
            var short = csvSafe(s)
            while short.utf8.count > 49 { short.removeLast() }
            return short.trimmingCharacters(in: .whitespaces)
        }

        var result = self
        var present = Set<Int>()
        for i in result.rows.indices {
            let tg = result.rows[i].talkgroup
            present.insert(tg)
            if result.rows[i].fields.count > 1, let m = mode(for: tg, listed: result.rows[i].fields[1]) {
                result.rows[i].fields[1] = m
            }
            if let name = overrides.names[tg], result.rows[i].fields.count > 2 {
                result.rows[i].fields[2] = shortName(name)
                if let fullIndex {
                    while result.rows[i].fields.count <= fullIndex { result.rows[i].fields.append("") }
                    result.rows[i].fields[fullIndex] = csvSafe(name)
                }
            }
        }
        let extra = Set(overrides.names.keys).union(overrides.lockedOut).union(overrides.alwaysAllowed)
            .union(encrypted).subtracting(present)
        for tg in extra.sorted() {
            let name = overrides.names[tg]
            var fields = [String(tg), mode(for: tg, listed: nil) ?? "A",
                          name.map(shortName) ?? (encrypted.contains(tg) ? "Encrypted TG \(tg)" : "TG \(tg)"),
                          encrypted.contains(tg) && name == nil ? "Encrypted" : ""]
            if let fullIndex {
                while fields.count <= fullIndex { fields.append("") }
                fields[fullIndex] = name.map(csvSafe) ?? ""
            }
            result.rows.append(Row(talkgroup: tg, fields: fields))
        }
        return result
    }

    var csvText: String {
        ([header] + rows.map { $0.fields.joined(separator: ",") }).joined(separator: "\n") + "\n"
    }
}

/// Per-talkgroup counts of finished clear and encrypted calls for one system,
/// persisted between runs. dsd-neo's own `--enc-lockout` skips encrypted calls
/// only for the current session, and some talkgroups mix clear and encrypted
/// traffic, so a talkgroup is locked out permanently only once it has carried
/// several encrypted calls and never a clear one.
nonisolated struct DsdNeoTalkgroupLedger: Codable, Equatable {
    struct Counts: Codable, Equatable {
        var clear = 0
        var encrypted = 0
        /// When the last call ended; nil in ledgers saved before this existed.
        var lastHeard: Date?
    }

    /// Encrypted calls, with no clear call, before a talkgroup is locked out.
    static let lockoutThreshold = 3

    var counts: [Int: Counts] = [:]

    mutating func record(_ call: DsdNeoCallRecord, at now: Date = Date()) {
        guard call.isGroupCall, call.talkgroup > 0 else { return }
        if call.encrypted {
            counts[call.talkgroup, default: Counts()].encrypted += 1
        } else {
            counts[call.talkgroup, default: Counts()].clear += 1
        }
        counts[call.talkgroup]?.lastHeard = now
    }

    var lockedOut: Set<Int> {
        Set(counts.compactMap { tg, c in
            c.clear == 0 && c.encrypted >= Self.lockoutThreshold ? tg : nil
        })
    }
}
