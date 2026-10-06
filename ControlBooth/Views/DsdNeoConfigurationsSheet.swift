import SwiftUI

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
}
