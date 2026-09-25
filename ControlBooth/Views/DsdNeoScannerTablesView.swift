import SwiftUI

/// One talkgroup in the dsd-neo Scanner tab's Talkgroups view: from the
/// talkgroup list, heard on the air, or named/locked by the user.
struct DsdNeoTalkgroupRow: Identifiable, Equatable {
    let id: Int
    var listName: String
    var name: String
    var clearCalls: Int
    var encryptedCalls: Int
    var lastHeard: Date?
    var policy: DsdNeoTalkgroupOverrides.Policy
    /// Locked out automatically for carrying only encrypted calls.
    var encryptionLocked: Bool
    var inList: Bool

    var heard: Bool { clearCalls + encryptedCalls > 0 }
    var calls: Int { clearCalls + encryptedCalls }
    var lastHeardSort: Date { lastHeard ?? .distantPast }

    static func rows(list: DsdNeoGroupList, ledger: DsdNeoTalkgroupLedger,
                     overrides: DsdNeoTalkgroupOverrides, encryptionLockout: Bool) -> [DsdNeoTalkgroupRow] {
        let listNames = list.displayNames
        let autoLocked = encryptionLockout ? ledger.lockedOut.subtracting(overrides.alwaysAllowed) : []
        let ids = Set(listNames.keys).union(ledger.counts.keys).union(overrides.names.keys)
            .union(overrides.lockedOut).union(overrides.alwaysAllowed)
        return ids.map { tg in
            let counts = ledger.counts[tg]
            let listName = listNames[tg] ?? ""
            return DsdNeoTalkgroupRow(id: tg, listName: listName, name: overrides.names[tg] ?? listName,
                                      clearCalls: counts?.clear ?? 0, encryptedCalls: counts?.encrypted ?? 0,
                                      lastHeard: counts?.lastHeard, policy: overrides.policy(for: tg),
                                      encryptionLocked: autoLocked.contains(tg), inList: listNames[tg] != nil)
        }
    }
}

/// The Talkgroups view: every talkgroup the list names or the scanner has
/// heard, with call counts, editable names and a lockout policy.
struct DsdNeoTalkgroupsView: View {
    let rows: [DsdNeoTalkgroupRow]
    let lockoutChangesPending: Bool
    let isRunning: Bool
    let onRename: (Int, String) -> Void
    let onPolicy: (Int, DsdNeoTalkgroupOverrides.Policy) -> Void
    let onRestart: () -> Void

    @State private var search = ""
    @State private var heardOnly = true
    // By number: the scanner updates call counts and times live, and a
    // live-updating sort key would move rows out from under an edit.
    @State private var sortOrder = [KeyPathComparator(\DsdNeoTalkgroupRow.id)]
    @State private var editedNames: [Int: String] = [:]

    private var visibleRows: [DsdNeoTalkgroupRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            (!heardOnly || row.heard)
                && (query.isEmpty || String(row.id).contains(query) || row.name.lowercased().contains(query))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search talkgroups", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Heard Only", isOn: $heardOnly)
                Spacer()
                Text("\(visibleRows.count) of \(rows.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            Table(visibleRows, sortOrder: $sortOrder) {
                TableColumn("TG", value: \.id) { row in
                    Text(String(row.id)).monospacedDigit()
                }
                .width(min: 50, ideal: 60, max: 80)
                TableColumn("Name") { row in
                    TextField(row.inList ? "" : "Unnamed", text: nameBinding(for: row))
                        .textFieldStyle(.plain)
                        .onSubmit { commitName(for: row) }
                        .help(row.inList && row.name != row.listName ? "List name: \(row.listName)" : row.name)
                }
                .width(min: 180, ideal: 320)
                TableColumn("Calls", value: \.calls) { row in
                    if row.heard {
                        Text(row.encryptedCalls > 0 ? "\(row.clearCalls) clear · \(row.encryptedCalls) encrypted"
                                                    : "\(row.clearCalls) clear")
                            .foregroundStyle(row.clearCalls == 0 ? .orange : .primary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 140)
                TableColumn("Last Heard", value: \.lastHeardSort) { row in
                    if let date = row.lastHeard {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 110)
                TableColumn("Status") { row in
                    HStack(spacing: 4) {
                        Picker("", selection: Binding(get: { row.policy }, set: { onPolicy(row.id, $0) })) {
                            ForEach(DsdNeoTalkgroupOverrides.Policy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if row.policy == .automatic && row.encryptionLocked {
                            Image(systemName: "lock.fill").foregroundStyle(.orange)
                                .help("Locked out: only encrypted calls heard")
                        }
                    }
                }
                .width(min: 140, ideal: 170)
            }
            if lockoutChangesPending && isRunning {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Lockout changes take effect when dsd-neo restarts.")
                    Spacer()
                    Button("Restart dsd-neo Now", action: onRestart)
                }
                .font(.caption)
                .padding(8)
                .background(.bar)
            }
        }
    }

    private func nameBinding(for row: DsdNeoTalkgroupRow) -> Binding<String> {
        Binding(get: { editedNames[row.id] ?? row.name },
                set: { editedNames[row.id] = $0 })
    }

    private func commitName(for row: DsdNeoTalkgroupRow) {
        guard let edited = editedNames.removeValue(forKey: row.id) else { return }
        // Typing the list's own name back (or clearing it) removes the override.
        onRename(row.id, edited == row.listName ? "" : edited)
    }
}

/// The Sites view: this system's sites as its control channels announce
/// them, with a button to monitor one of them instead.
struct DsdNeoSitesView: View {
    let table: DsdNeoSiteTable
    let currentControlChannelHz: Int
    let onUse: (Int) -> Void

    var body: some View {
        let sites = table.listedSites
        if sites.isEmpty {
            ContentUnavailableView(
                "No Sites Yet",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("While the scanner runs, the control channel announces its own site and its neighbours; they appear here.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("System \(table.system ?? "?") — \(sites.count) site(s). Use one to monitor its control channel instead, then Save.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                Table(sites) {
                    TableColumn("Site") { site in
                        HStack(spacing: 4) {
                            Text("RFSS \(site.rfss) · Site \(site.site)")
                            if site.isHome {
                                Text("home").font(.caption2).padding(.horizontal, 4)
                                    .background(.green.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                    .width(min: 150, ideal: 190)
                    TableColumn("Control Channel") { site in
                        if let hz = table.frequency(of: site) {
                            Text(DsdNeoScannerSettings.megahertz(hz).dropLast() + " MHz").monospacedDigit()
                        } else {
                            Text(site.channel.map { String(format: "channel %04X", $0) } ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Last Heard") { site in
                        Text(site.lastSeen, format: .relative(presentation: .named))
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("") { site in
                        if let hz = table.frequency(of: site) {
                            if hz == currentControlChannelHz {
                                Text("Monitoring").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Use") { onUse(hz) }
                            }
                        }
                    }
                    .width(min: 80, ideal: 90)
                }
            }
        }
    }
}
