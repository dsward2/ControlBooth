import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "dsd-neo Scanner" tab: dsd-neo's settings, Start/Stop for the
/// "dsd-neo Scanner" pipeline (announced to AntennaHead like the pipeline
/// list's Play button), status, and dsd-neo's live terminal.
struct DsdNeoScannerView: View {
    @Environment(PipelineStore.self) private var store
    @Environment(PipelineRunner.self) private var runner

    @State private var draft = DsdNeoScannerSettings.load()
    @State private var saved = DsdNeoScannerSettings.load()
    @State private var controlChannelMHz = ""
    @State private var extraArgumentsText = ""
    @State private var devices: [String] = []
    @State private var installation = DsdNeoInstallation.detect()
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var busy = false
    @State private var pane: Pane = .terminal
    /// The talkgroup list in the settings, and the saved per-system state,
    /// for the Talkgroups and Sites views while the scanner isn't running.
    @State private var groupList = DsdNeoGroupList()
    @State private var savedState = DsdNeoScanner.savedState(for: DsdNeoScannerSettings.load())

    private enum Pane: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case talkgroups = "Talkgroups"
        case sites = "Sites"
        var id: String { rawValue }
    }

    private var scanner: DsdNeoScanner { runner.dsdNeoScanner }

    private var scannerPipeline: Pipeline? {
        store.pipelines.first { $0.stages.first.map(PipelineRunner.isDsdNeoScannerStage) == true }
    }

    private var isRunning: Bool {
        guard let pipeline = scannerPipeline else { return false }
        return runner.isRunning(pipeline) && scanner.isActive
    }

    private var hasChanges: Bool {
        var a = editedSettings, b = saved
        a.systemID = nil
        b.systemID = nil
        return a != b
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                settingsForm
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                VStack(spacing: 0) {
                    Picker("View", selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(6)
                    switch pane {
                    case .terminal: terminalPane
                    case .talkgroups: talkgroupsPane
                    case .sites: sitesPane
                    }
                }
                .frame(minWidth: 480)
            }
        }
        .navigationTitle("dsd-neo Scanner")
        .onAppear {
            controlChannelMHz = draft.controlChannelHz > 0
                ? DsdNeoScannerSettings.megahertz(draft.controlChannelHz).dropLast().description : ""
            extraArgumentsText = draft.extraArguments.joined(separator: " ")
            refreshDevices()
            reloadGroupList()
            savedState = DsdNeoScanner.savedState(for: DsdNeoScannerSettings.load())
        }
        .onChange(of: draft.groupListPath) { reloadGroupList() }
        .onChange(of: scanner.isActive) { savedState = DsdNeoScanner.savedState(for: DsdNeoScannerSettings.load()) }
        .alert("dsd-neo Scanner", isPresented: Binding(get: { errorMessage != nil },
                                                        set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Talkgroup List", isPresented: Binding(get: { infoMessage != nil },
                                                       set: { if !$0 { infoMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if let detail = statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if hasChanges {
                Button("Revert") { revert() }
                    .disabled(busy)
                Button(isRunning ? "Save & Apply" : "Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(busy)
                    .help(isRunning ? "Save and restart dsd-neo with these settings; the pipeline keeps playing." : "")
            }
            if isRunning {
                Button("Stop", systemImage: "stop.fill") { stop() }
                    .disabled(busy)
            } else {
                Button("Start", systemImage: "play.fill") { start() }
                    .disabled(busy || installation == nil || installation?.isQuarantined == true
                              || !editedSettings.isConfigured)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        let color: Color
        switch scanner.state {
        case .running: color = .green
        case .restarting: color = .orange
        case .failed: color = .red
        case .idle: color = .secondary
        }
        return Circle().fill(color).frame(width: 10, height: 10)
    }

    private var statusTitle: String {
        switch scanner.state {
        case .running:
            return scanner.nowPlayingText.map { "Listening — \($0)" } ?? "Running — waiting for a clear call"
        case .restarting(let why): return "Restarting dsd-neo (\(why))"
        case .failed: return "Stopped after an error"
        case .idle: return "Not running"
        }
    }

    private var statusDetail: String? {
        if case .failed(let message) = scanner.state { return message }
        guard scanner.isActive else { return nil }
        var parts: [String] = []
        if scanner.restartCount > 0 {
            parts.append("Restarted \(scanner.restartCount)×"
                         + (scanner.lastRestartReason.map { " — last: \($0)" } ?? ""))
        }
        if !scanner.lockedOutTalkgroups.isEmpty {
            parts.append("\(scanner.lockedOutTalkgroups.count) encrypted talkgroup(s) locked out")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Settings

    private var editedSettings: DsdNeoScannerSettings {
        var settings = draft
        settings.controlChannelHz = Self.hertz(fromMegahertz: controlChannelMHz) ?? 0
        // The scanner fills in the network it finds; keep it unless the
        // control channel changed (then it's found again).
        let stored = DsdNeoScannerSettings.load()
        settings.systemID = stored.controlChannelHz == settings.controlChannelHz ? stored.systemID : nil
        settings.extraArguments = extraArgumentsText.split(whereSeparator: \.isWhitespace).map(String.init)
        return settings
    }

    private var settingsForm: some View {
        Form {
            if let problem = installationProblem {
                Section { problem }
            }
            Section("System") {
                TextField("Control Channel (MHz)", text: $controlChannelMHz, prompt: Text("853.1875"))
                LabeledContent("Talkgroup List") {
                    HStack {
                        Text(draft.groupListPath.isEmpty ? "None"
                             : (draft.groupListPath as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(draft.groupListPath.isEmpty ? .secondary : .primary)
                            .help(draft.groupListPath)
                        Button("Import…") { importGroupList() }
                            .help("Choose an OP25 TSV, RadioReference CSV, SDRTrunk playlist or dsd-neo CSV.")
                        if !draft.groupListPath.isEmpty {
                            Button("Clear") { draft.groupListPath = "" }
                        }
                    }
                }
                Toggle("Lock Out Encrypted Talkgroups", isOn: $draft.encryptionLockout)
                    .help("Skip encrypted calls, and permanently lock out talkgroups that only ever carry encrypted calls.")
            }
            Section("RTL-SDR") {
                Picker("Device", selection: $draft.rtlSerial) {
                    if draft.rtlSerial.isEmpty { Text("Choose…").tag("") }
                    ForEach(deviceChoices, id: \.self) { serial in
                        Text(devices.contains(serial) ? serial : "\(serial) (not connected)").tag(serial)
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh Devices") { refreshDevices() }
                        .controlSize(.small)
                }
                TextField("Gain (dB, 0 = auto)", value: $draft.gainDB, format: .number)
                TextField("Frequency Correction (ppm)", value: $draft.ppm, format: .number)
                Picker("Bandwidth", selection: $draft.bandwidthKHz) {
                    ForEach([12, 24, 48], id: \.self) { Text("\($0) kHz").tag($0) }
                }
            }
            Section {
                TextField("Extra dsd-neo Arguments", text: $extraArgumentsText, prompt: Text("e.g. -W"))
                TextField("Audio Port", value: $draft.audioPort, format: .number.grouping(.never))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Audio Port changes apply the next time the scanner starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isRunning {
                let lockouts = DsdNeoScanner.savedLockouts(for: saved)
                if !lockouts.isEmpty {
                    Section("Encrypted Talkgroups") {
                        LabeledContent("Locked Out", value: "\(lockouts.count) talkgroup(s)")
                        Button("Forget Encrypted Talkgroups") {
                            DsdNeoScanner.forgetEncryptionHistory(for: saved)
                            saved = saved   // refresh the count
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The connected serials, plus the configured one if it isn't connected.
    private var deviceChoices: [String] {
        var choices = devices
        if !draft.rtlSerial.isEmpty, !choices.contains(draft.rtlSerial) { choices.append(draft.rtlSerial) }
        return choices
    }

    @ViewBuilder
    private var installationProblem: (some View)? {
        if let installation {
            if installation.isQuarantined {
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS is blocking dsd-neo", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("It was downloaded from the internet. Run this in Terminal, then click Check Again:")
                        .font(.caption)
                    Text(installation.quarantineFixCommand)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installation.quarantineFixCommand, forType: .string)
                        }
                        Button("Check Again") { self.installation = DsdNeoInstallation.detect() }
                    }
                    .controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("dsd-neo isn't installed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Install the dsd-neo macOS portable build (github.com/arancormonk/dsd-neo) as \(DsdNeoInstallation.standardRoot.path).")
                    .font(.caption)
                Button("Check Again") { self.installation = DsdNeoInstallation.detect() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Terminal

    private var terminalPane: some View {
        ZStack {
            DsdNeoTerminalView(scanner: scanner)
            if !scanner.isActive {
                VStack(spacing: 6) {
                    Image(systemName: "terminal").font(.largeTitle)
                    Text("dsd-neo isn't running").font(.headline)
                    Text("Start the scanner to see dsd-neo's live display here. Click in it to type dsd-neo's keyboard commands.")
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .background(Color.black)
    }

    // MARK: Talkgroups and Sites

    private var talkgroupsPane: some View {
        let running = scanner.isActive
        let ledger = running ? scanner.ledger : savedState.ledger
        let overrides = running ? scanner.overrides : savedState.overrides
        return DsdNeoTalkgroupsView(
            rows: DsdNeoTalkgroupRow.rows(list: groupList, ledger: ledger, overrides: overrides,
                                          encryptionLockout: saved.encryptionLockout),
            lockoutChangesPending: scanner.lockoutChangesPending,
            isRunning: isRunning,
            onRename: { tg, name in updateOverrides { $0.setName(name, for: tg) } },
            onPolicy: { tg, policy in updateOverrides { $0.setPolicy(policy, for: tg) } },
            onRestart: { restartScanner() })
    }

    private var sitesPane: some View {
        DsdNeoSitesView(table: scanner.isActive ? scanner.sites : savedState.sites,
                        currentControlChannelHz: editedSettings.controlChannelHz,
                        onUse: { hz in
                            controlChannelMHz = String(DsdNeoScannerSettings.megahertz(hz).dropLast())
                        })
    }

    private func updateOverrides(_ change: (inout DsdNeoTalkgroupOverrides) -> Void) {
        let current = DsdNeoScannerSettings.load()
        var overrides = scanner.isActive ? scanner.overrides : DsdNeoScanner.savedState(for: current).overrides
        change(&overrides)
        scanner.saveOverrides(overrides, for: current)
        savedState = DsdNeoScanner.savedState(for: current)
    }

    private func restartScanner() {
        do {
            try runner.applyDsdNeoSettings(DsdNeoScannerSettings.load())
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func reloadGroupList() {
        let path = (draft.groupListPath as NSString).expandingTildeInPath
        guard !path.isEmpty, let text = Self.readText(URL(fileURLWithPath: path)) else {
            groupList = DsdNeoGroupList()
            return
        }
        groupList = DsdNeoGroupList(csv: text)
    }

    /// Imports a talkgroup list. A dsd-neo CSV is used where it is; other
    /// formats are converted into ControlBooth's dsd-neo folder.
    private func importGroupList() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a talkgroup list: OP25 TSV, RadioReference CSV, SDRTrunk playlist, or dsd-neo CSV."
        panel.prompt = "Import"
        if !draft.groupListPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.groupListPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = Self.readText(url) else {
            errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        do {
            let result = try DsdNeoTalkgroupImport.convert(text)
            var path = url.path
            if result.format != .dsdNeo {
                let folder = DsdNeoScanner.directory.appendingPathComponent("lists", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")
                try result.list.csvText.write(to: destination, atomically: true, encoding: .utf8)
                path = destination.path
            }
            draft.groupListPath = path
            var message = "Imported \(result.list.rows.count) talkgroups from \(url.lastPathComponent) (\(result.format.rawValue))."
            if result.skipped > 0 { message += " \(result.skipped) entries couldn't be read." }
            message += isRunning ? " Click Save & Apply to use it." : " Click Save to use it."
            infoMessage = message
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// UTF-8, falling back to Latin-1 (older Windows exports).
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: Actions

    private func start() {
        guard !hasChanges || commitSettings(apply: false) else { return }
        guard let pipeline = scannerPipeline ?? restoreScannerPipeline() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await runner.startAnnouncingToAntennaHead(pipeline)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    private func stop() {
        guard let pipeline = scannerPipeline else { return }
        runner.stopAnnouncingToAntennaHead(pipeline)
    }

    private func save() {
        _ = commitSettings(apply: isRunning)
    }

    /// Saves the edited settings (and relaunches a running dsd-neo with them
    /// when `apply`). False when they couldn't be saved.
    private func commitSettings(apply: Bool) -> Bool {
        let settings = editedSettings
        if !controlChannelMHz.trimmingCharacters(in: .whitespaces).isEmpty, settings.controlChannelHz == 0 {
            errorMessage = "“\(controlChannelMHz)” isn't a frequency in MHz."
            return false
        }
        draft = settings
        do {
            if apply {
                try runner.applyDsdNeoSettings(settings)
            } else {
                settings.save()
            }
            saved = settings
            return true
        } catch {
            saved = DsdNeoScannerSettings.load()
            errorMessage = "\(error)"
            return false
        }
    }

    private func revert() {
        draft = saved
        controlChannelMHz = saved.controlChannelHz > 0
            ? DsdNeoScannerSettings.megahertz(saved.controlChannelHz).dropLast().description : ""
        extraArgumentsText = saved.extraArguments.joined(separator: " ")
    }

    /// Re-adds the "dsd-neo Scanner" pipeline if the user deleted it.
    private func restoreScannerPipeline() -> Pipeline? {
        var pipeline = Pipeline.prototype(name: PipelineStore.dsdNeoScannerPipelineName,
                                          sortOrder: (store.pipelines.map(\.sortOrder).max() ?? -1) + 1)
        pipeline.stages = [PipelineStage(path: PipelineRunner.dsdNeoScannerTool)]
        do {
            return try store.save(pipeline)
        } catch {
            errorMessage = "Could not add the dsd-neo Scanner pipeline: \(error)"
            return nil
        }
    }

    private func refreshDevices() {
        Task {
            devices = await Task.detached(priority: .userInitiated) {
                let backend = LibRTLSDRBackend()
                return (0..<backend.deviceCount()).compactMap { backend.serial(at: $0) }.filter { !$0.isEmpty }
            }.value
        }
    }

    /// "853.1875" → 853187500; nil unless it's a positive number.
    static func hertz(fromMegahertz text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "MHz", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard let mhz = Double(trimmed), mhz > 0 else { return nil }
        return Int((mhz * 1_000_000).rounded())
    }
}
