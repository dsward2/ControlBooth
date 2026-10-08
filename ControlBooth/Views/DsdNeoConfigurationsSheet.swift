import SwiftUI
import UniformTypeIdentifiers

/// Add, rename, duplicate, delete and edit the control channels of the
/// scanner's configurations (AWIN, CWIN, …). Edits the in-memory set the
/// scanner tab owns; the tab saves it with the rest of the settings.
struct DsdNeoConfigurationsSheet: View {
    @Binding var store: DsdNeoConfigurationSet
    /// What a new configuration starts from: the scanner's current system.
    let current: DsdNeoScannerSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var channelsText = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.configurations) { configuration in
                        Text(configuration.name.isEmpty ? "Untitled" : configuration.name)
                            .tag(configuration.id)
                    }
                }
                .frame(width: 170)
                Divider()
                detail
            }
            Divider()
            HStack {
                Button("New", systemImage: "plus") { add() }
                    .help("A new configuration that starts from the scanner's current system.")
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate() }
                    .disabled(selected == nil)
                Button("Delete", systemImage: "minus") { delete() }
                    .disabled(selected == nil || store.configurations.count < 2)
                Divider().frame(height: 16)
                Button("Import…", systemImage: "square.and.arrow.down") { importFile() }
                    .help("Add configurations from a file exported by ControlBooth, including their talkgroup lists.")
                Button("Export…", systemImage: "square.and.arrow.up") { exportFile() }
                    .help("Save all configurations, with their talkgroup lists, to one file.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 560, height: 380)
        .onAppear {
            selection = store.activeID ?? store.configurations.first?.id
            loadChannelsText()
        }
        .onChange(of: selection) { loadChannelsText() }
        .alert("dsd-neo Configurations", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var selected: DsdNeoConfiguration? {
        store.configurations.first { $0.id == selection }
    }

    private var selectedIndex: Int? {
        store.configurations.firstIndex { $0.id == selection }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = selectedIndex {
            Form {
                TextField("Name", text: $store.configurations[index].name)
                Section {
                    TextEditor(text: $channelsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 130)
                        .onChange(of: channelsText) { applyChannelsText(at: index) }
                } header: {
                    Text("Control Channels")
                } footer: {
                    Text("One per line: the frequency in MHz, then an optional site name — e.g. 854.3625 Clearwell Road.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !store.configurations[index].groupListPath.isEmpty {
                    LabeledContent("Talkgroup List",
                                   value: (store.configurations[index].groupListPath as NSString).lastPathComponent)
                }
                if !store.configurations[index].rtlSerial.isEmpty {
                    LabeledContent("RTL-SDR", value: store.configurations[index].rtlSerial)
                }
            }
            .formStyle(.grouped)
        } else {
            Text("No configuration selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadChannelsText() {
        channelsText = selected?.channelsText ?? ""
    }

    /// Keeps the selected channel valid as the list changes: if it was
    /// removed, falls back to the first one.
    private func applyChannelsText(at index: Int) {
        guard store.configurations.indices.contains(index) else { return }
        let channels = DsdNeoConfiguration.parseChannels(channelsText)
        guard channels != store.configurations[index].controlChannels else { return }
        store.configurations[index].controlChannels = channels
        let selectedHz = store.configurations[index].selectedControlChannelHz
        if !channels.contains(where: { $0.hz == selectedHz }), let first = channels.first {
            store.configurations[index].selectedControlChannelHz = first.hz
        }
    }

    private func add() {
        let configuration = DsdNeoConfiguration(
            name: "New System",
            controlChannels: current.controlChannelHz > 0
                ? [DsdNeoControlChannel(hz: current.controlChannelHz, label: "")] : [],
            selectedControlChannelHz: current.controlChannelHz,
            groupListPath: current.groupListPath, rtlSerial: current.rtlSerial)
        store.configurations.append(configuration)
        selection = configuration.id
    }

    private func duplicate() {
        guard var copy = selected else { return }
        copy.id = UUID()
        copy.name += " Copy"
        copy.systemID = nil
        store.configurations.append(copy)
        selection = copy.id
    }

    private func delete() {
        guard let index = selectedIndex, store.configurations.count > 1 else { return }
        let removed = store.configurations.remove(at: index)
        if store.activeID == removed.id { store.activeID = store.configurations.first?.id }
        selection = store.configurations[min(index, store.configurations.count - 1)].id
    }

    // MARK: Export / import

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dsd-neo-configurations.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Saves every configuration with its talkgroup list, to move to another Mac or keep as a backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DsdNeoConfigurationExchange.export(store) { path in
                DsdNeoScannerView.readText(URL(fileURLWithPath: path))
            }
            try data.write(to: url, options: .atomic)
            message = "Exported \(store.configurations.count) configuration(s) to \(url.lastPathComponent)."
        } catch {
            message = "Couldn't export: \(error)"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a dsd-neo configurations file exported by ControlBooth."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let folder = DsdNeoScanner.directory.appendingPathComponent("lists", isDirectory: true)
            let result = try DsdNeoConfigurationExchange.importing(data, into: store, listsFolder: folder)
            store = result.set
            if let first = result.report.added.first,
               let added = store.configurations.first(where: { $0.name == first }) { selection = added.id }
            var text = "Imported \(result.report.added.count) configuration(s)"
            if result.report.listsWritten > 0 { text += " and \(result.report.listsWritten) talkgroup list(s)" }
            text += "."
            if !result.report.renamed.isEmpty {
                text += " Renamed to avoid clashes: \(result.report.renamed.joined(separator: ", "))."
            }
            message = text + " Existing configurations were not changed."
        } catch {
            message = "Couldn't import: \(error)"
        }
    }
}
