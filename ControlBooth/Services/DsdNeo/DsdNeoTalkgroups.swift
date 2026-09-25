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
        var result = self
        var present = Set<Int>()
        for i in result.rows.indices {
            let tg = result.rows[i].talkgroup
            present.insert(tg)
            if lockedOut.contains(tg), result.rows[i].fields.count > 1 {
                result.rows[i].fields[1] = "DE"
            }
        }
        for tg in lockedOut.subtracting(present).sorted() {
            result.rows.append(Row(talkgroup: tg, fields: [String(tg), "DE", "Encrypted TG \(tg)", "Encrypted"]))
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
    }

    /// Encrypted calls, with no clear call, before a talkgroup is locked out.
    static let lockoutThreshold = 3

    var counts: [Int: Counts] = [:]

    mutating func record(_ call: DsdNeoCallRecord) {
        guard call.isGroupCall, call.talkgroup > 0 else { return }
        if call.encrypted {
            counts[call.talkgroup, default: Counts()].encrypted += 1
        } else {
            counts[call.talkgroup, default: Counts()].clear += 1
        }
    }

    var lockedOut: Set<Int> {
        Set(counts.compactMap { tg, c in
            c.clear == 0 && c.encrypted >= Self.lockoutThreshold ? tg : nil
        })
    }
}
