import SwiftUI

/// Form section choosing the upstream USB hub port that is power cycled when
/// an RTL-SDR wedges (see `USBHubPowerSettings`). Saves as it changes: the
/// choice belongs to the hardware, not to a scanner configuration.
struct USBHubPowerSection: View {
    @State private var settings = USBHubPowerSettings.load()
    @State private var hubs: [USBHub] = []
    @State private var listingError: String?
    @State private var cycling = false
    @State private var confirming = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private let cycler = USBHubPowerCycler()

    private struct Choice: Identifiable, Hashable {
        var id: String { "\(location)|\(port)" }
        var location: String
        var hubID: String
        var port: Int
        var deviceID: String
        var label: String
    }

    /// Every port of a per-port-switchable hub that has something plugged in.
    private var choices: [Choice] {
        hubs.filter(\.switchesPerPort).flatMap { hub in
            hub.ports.compactMap { port in
                guard let deviceID = port.deviceID else { return nil }
                let name = port.deviceName ?? deviceID
                return Choice(location: hub.location, hubID: hub.usbID, port: port.number, deviceID: deviceID,
                              label: "Hub \(hub.location), port \(port.number): \(name)")
            }
        }
    }

    private var selectionID: String {
        settings.isConfigured ? "\(settings.hubLocation)|\(settings.port)" : ""
    }

    var body: some View {
        Section {
            Toggle("Power cycle a USB hub if the RTL-SDR wedges", isOn: $settings.enabled)
            if settings.enabled {
                if !cycler.isInstalled {
                    Label(String(describing: USBHubPowerError.uhubctlMissing), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Picker("Hub Port", selection: Binding(get: { selectionID }, set: choose)) {
                        if selectionID.isEmpty { Text("Choose…").tag("") }
                        if !selectionID.isEmpty, !choices.contains(where: { $0.id == selectionID }) {
                            Text("Hub \(settings.hubLocation), port \(settings.port) (not found)").tag(selectionID)
                        }
                        ForEach(choices) { Text($0.label).tag($0.id) }
                    }
                    HStack {
                        Button("Refresh Hubs") { refresh() }
                        Spacer()
                        Button("Power Cycle Now…") { confirming = true }
                            .disabled(!settings.isConfigured || cycling)
                    }
                    .controlSize(.small)
                    if cycling { ProgressView().controlSize(.small) }
                }
                if let listingError {
                    Text(listingError).font(.caption).foregroundStyle(.red)
                }
                if let resultMessage {
                    Text(resultMessage).font(.caption).foregroundStyle(resultIsError ? .red : .secondary)
                }
            }
        } header: {
            Text("USB Hub Power")
        } footer: {
            Text("A wedged RTL-SDR only recovers when it loses power. If your RTL-SDRs are on a hub that can't "
                 + "switch its own ports, choose the port of the hub above it that the RTL-SDR hub is plugged "
                 + "into: when the scanner gets no signal after restarting, that port is switched off and on, "
                 + "which drops everything on the hub below for a few seconds. Only hubs that switch ports "
                 + "individually are listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: settings) { _, new in new.save() }
        .onChange(of: settings.enabled) { _, enabled in if enabled, hubs.isEmpty { refresh() } }
        .task { if settings.enabled { refresh() } }
        .confirmationDialog("Power cycle hub \(settings.hubLocation), port \(settings.port)?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Power Cycle", role: .destructive) { cycleNow() }
        } message: {
            Text("Everything on that port, including every RTL-SDR on the hub below it, loses power for "
                 + "\(settings.offSeconds) seconds. A running pipeline using them will stop receiving.")
        }
    }

    private func choose(_ id: String) {
        guard let choice = choices.first(where: { $0.id == id }) else { return }
        settings.hubLocation = choice.location
        settings.hubID = choice.hubID
        settings.port = choice.port
        settings.portDeviceID = choice.deviceID
    }

    private func refresh() {
        let cycler = self.cycler
        Task {
            let result = await Task.detached { Result { try cycler.listHubs() } }.value
            switch result {
            case .success(let found):
                hubs = found
                listingError = nil
            case .failure(let error):
                listingError = "\(error)"
            }
        }
    }

    private func cycleNow() {
        let cycler = self.cycler, settings = self.settings
        cycling = true
        resultMessage = nil
        Task {
            let result = await Task.detached { Result { try cycler.cycle(settings) } }.value
            cycling = false
            switch result {
            case .success:
                resultIsError = false
                resultMessage = "Power cycled hub \(settings.hubLocation), port \(settings.port)."
                refresh()
            case .failure(let error):
                resultIsError = true
                resultMessage = "\(error)"
            }
        }
    }
}
