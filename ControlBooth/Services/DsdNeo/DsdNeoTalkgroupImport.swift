import Foundation

/// Converts talkgroup lists from other scanner software into a dsd-neo group
/// list (`DEC,Mode,Name,Tag,FullName`). Name is the short label dsd-neo shows
/// (it keeps 49 bytes); FullName is what Now Playing shows.
nonisolated enum DsdNeoTalkgroupImport {
    enum Format: String, Equatable {
        case dsdNeo = "dsd-neo CSV"
        case op25 = "OP25 TSV"
        case radioReference = "RadioReference CSV"
        case sdrTrunk = "SDRTrunk playlist"
    }

    struct Result: Equatable {
        var format: Format
        var list: DsdNeoGroupList
        /// Rows that couldn't be read (not counting headers and blank lines).
        var skipped: Int
    }

    enum ImportError: Error, CustomStringConvertible, Equatable {
        case unrecognized
        case empty(Format)

        var description: String {
            switch self {
            case .unrecognized:
                return "This isn't a talkgroup list ControlBooth can read. It reads OP25 talkgroup TSV files, "
                    + "RadioReference talkgroup CSV exports, SDRTrunk playlists and dsd-neo group CSVs."
            case .empty(let format):
                return "No talkgroups were found in this \(format.rawValue)."
            }
        }
    }

    static let header = "DEC,Mode,Name,Tag,FullName"
    /// dsd-neo truncates names at 49 bytes.
    static let nameLimit = 49

    static func convert(_ text: String) throws -> Result {
        let format = try detect(text)
        let result: Result
        switch format {
        case .dsdNeo: result = fromDsdNeo(text)
        case .op25: result = fromOP25(text)
        case .radioReference: result = fromRadioReference(text)
        case .sdrTrunk: result = fromSDRTrunk(text)
        }
        guard !result.list.rows.isEmpty else { throw ImportError.empty(format) }
        return result
    }

    static func detect(_ text: String) throws -> Format {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.contains("<alias") || trimmed.contains("<playlist") {
            return .sdrTrunk
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { throw ImportError.unrecognized }
        let header = parseCSVLine(first).map { $0.lowercased() }
        if header.contains("alpha tag") && header.contains("decimal") { return .radioReference }
        // OP25: "<number><TAB><name>" with no header.
        let tabbed = lines.prefix(20).filter { !$0.hasPrefix("#") }
        if !tabbed.isEmpty, tabbed.allSatisfy({ line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 && Int(parts[0].trimmingCharacters(in: .whitespaces)) != nil
        }) {
            return .op25
        }
        // dsd-neo: a header line, then "number,mode,name".
        if lines.count > 1 {
            let row = lines[1].split(separator: ",", omittingEmptySubsequences: false)
            if row.count >= 3, Int(row[0].trimmingCharacters(in: .whitespaces)) != nil { return .dsdNeo }
        }
        throw ImportError.unrecognized
    }

    // MARK: Formats

    private static func fromDsdNeo(_ text: String) -> Result {
        Result(format: .dsdNeo, list: DsdNeoGroupList(csv: text), skipped: 0)
    }

    /// `3<TAB>State Police: Troop A - …`, names optionally in quotes.
    private static func fromOP25(_ text: String) -> Result {
        var rows: [DsdNeoGroupList.Row] = []
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || raw.hasPrefix("#") { continue }
            let parts = raw.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let tg = Int(parts[0].trimmingCharacters(in: .whitespaces)), tg > 0 else {
                skipped += 1
                continue
            }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            rows.append(row(tg, mode: "A", name: name, tag: "", fullName: name))
        }
        return Result(format: .op25, list: DsdNeoGroupList(header: Self.header, rows: rows), skipped: skipped)
    }

    /// RadioReference's talkgroup download: `Decimal,Hex,Alpha Tag,Mode,
    /// Description,Tag,Category`. Mode letters: A analog, D P25 Phase 1, T
    /// TDMA; a capital E means always encrypted (locked out), a lowercase e
    /// only sometimes (kept).
    private static func fromRadioReference(_ text: String) -> Result {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let header = parseCSVLine(lines[0]).map { $0.lowercased() }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        let decimal = column("decimal")!, alpha = column("alpha tag")!
        let mode = column("mode"), description = column("description")
        let tag = column("tag"), category = column("category")

        var rows: [DsdNeoGroupList.Row] = []
        var skipped = 0
        for line in lines.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = parseCSVLine(line)
            func field(_ i: Int?) -> String {
                guard let i, i < fields.count else { return "" }
                return fields[i].trimmingCharacters(in: .whitespaces)
            }
            guard let tg = Int(field(decimal)), tg > 0 else { skipped += 1; continue }
            let rrMode = field(mode)
            let encrypted = rrMode.hasSuffix("E")
            let short = field(alpha).isEmpty ? field(description) : field(alpha)
            let full = field(description).isEmpty ? short : field(description)
            let group = [field(category), field(tag)].first { !$0.isEmpty } ?? ""
            rows.append(row(tg, mode: encrypted ? "DE" : "A", name: short, tag: group, fullName: full))
        }
        return Result(format: .radioReference, list: DsdNeoGroupList(header: Self.header, rows: rows), skipped: skipped)
    }

    /// SDRTrunk playlist aliases with APCO-25 talkgroup ids. An alias with
    /// priority -1 ("do not monitor") is locked out.
    private static func fromSDRTrunk(_ text: String) -> Result {
        let parser = SDRTrunkAliasParser()
        let xml = XMLParser(data: Data(text.utf8))
        xml.delegate = parser
        xml.parse()
        var rows: [DsdNeoGroupList.Row] = []
        var seen = Set<Int>()
        for alias in parser.aliases {
            for tg in alias.talkgroups where tg > 0 && seen.insert(tg).inserted {
                rows.append(row(tg, mode: alias.doNotMonitor ? "B" : "A", name: alias.name,
                                tag: alias.group, fullName: alias.name))
            }
        }
        return Result(format: .sdrTrunk, list: DsdNeoGroupList(header: Self.header, rows: rows), skipped: parser.skipped)
    }

    // MARK: Helpers

    /// A CSV-safe row: dsd-neo's CSV reader doesn't handle quoting, so commas
    /// in text become semicolons (`DsdNeoGroupList.displayNames` turns
    /// "; " back into ", " for Now Playing).
    private static func row(_ tg: Int, mode: String, name: String, tag: String, fullName: String) -> DsdNeoGroupList.Row {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: ",", with: ";")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var short = clean(name)
        while short.utf8.count > nameLimit { short.removeLast() }
        short = short.trimmingCharacters(in: .whitespaces)
        let shortName = short.isEmpty ? "TG \(tg)" : short
        let full = clean(fullName)
        return DsdNeoGroupList.Row(talkgroup: tg,
                                   fields: [String(tg), mode, shortName, clean(tag), full.isEmpty ? shortName : full])
    }

    /// One CSV line with RFC 4180 quoting ("a, b" and doubled "" quotes).
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }
}

/// Collects `<alias>` elements and their talkgroup `<id>`s from an SDRTrunk
/// playlist.
nonisolated private final class SDRTrunkAliasParser: NSObject, XMLParserDelegate {
    struct Alias {
        var name: String
        var group: String
        var talkgroups: [Int] = []
        var doNotMonitor = false
    }

    private(set) var aliases: [Alias] = []
    private(set) var skipped = 0
    private var current: Alias?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "alias":
            current = Alias(name: attributes["name"] ?? "", group: attributes["group"] ?? "")
        case "id":
            guard current != nil else { return }
            switch attributes["type"] {
            case "talkgroup":
                let protocolName = attributes["protocol"] ?? "APCO25"
                if protocolName == "APCO25", let value = attributes["value"].flatMap(Int.init) {
                    current?.talkgroups.append(value)
                } else {
                    skipped += 1
                }
            case "priority":
                if attributes["priority"] == "-1" { current?.doNotMonitor = true }
            default:
                break
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        if element == "alias", let alias = current {
            if !alias.talkgroups.isEmpty { aliases.append(alias) }
            current = nil
        }
    }
}
