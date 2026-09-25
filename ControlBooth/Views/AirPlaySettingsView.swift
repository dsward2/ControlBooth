import SwiftUI
import AirPlayReceiver

/// The three modes `AirPlaySettings.enabled`/`relayEnabled` combine into —
/// see `AirPlayReceiverService`'s type doc comment for why they're split.
private enum AirPlayMode: String, CaseIterable, Identifiable {
    case notInUse = "Not in Use"
    case receiving = "Receiving"
    case receivingAndRelaying = "Receiving & Relayed"

    var id: String { rawValue }

    init(enabled: Bool, relayEnabled: Bool) {
        switch (enabled, relayEnabled) {
        case (false, _): self = .notInUse
        case (true, false): self = .receiving
        case (true, true): self = .receivingAndRelaying
        }
    }

    var enabled: Bool { self != .notInUse }
    var relayEnabled: Bool { self == .receivingAndRelaying }
}

struct AirPlaySettingsView: View {
    @Environment(AirPlaySettingsStore.self) private var store
    @Environment(AirPlayReceiverService.self) private var service

    @State private var mode: AirPlayMode
    @State private var deviceName: String
    @State private var destinationHost: String
    @State private var destinationPort: Int
    @State private var errorMessage: String?

    init(settings: AirPlaySettings) {
        _mode = State(initialValue: AirPlayMode(enabled: settings.enabled, relayEnabled: settings.relayEnabled))
        _deviceName = State(initialValue: settings.deviceName)
        _destinationHost = State(initialValue: settings.destinationHost)
        _destinationPort = State(initialValue: settings.destinationPort)
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(AirPlayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Device Name", text: $deviceName)
                TextField("Destination Host", text: $destinationHost)
                TextField("Destination Port", value: $destinationPort, format: .number.grouping(.never))
            } header: {
                Text("AirPlay Receiver")
            } footer: {
                Text("\"Receiving\" advertises ControlBooth as an AirPlay speaker named \"\(deviceName)\" and decodes audio from a connected client without sending it anywhere. \"Receiving & Relayed\" also forwards the decoded PCM to \(destinationHost):\(String(destinationPort)) — normally AntennaHead, which can also switch this relay on/off remotely from its ControlBooth Remote Control page. Only one AirPlay receiver can be active on this Mac at a time — macOS's own built-in one (System Settings → General → AirDrop & Handoff) or this one — since both use RTSP port 5000.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Status", value: service.isRunning ? "Running" : "Stopped")
                if service.isRunning {
                    LabeledContent("Audio", value: service.isReceivingAudio ? "Receiving audio" : "Idle — no AirPlay client connected")
                    LabeledContent("Relay to AntennaHead", value: service.relayEnabled ? "On" : "Off")
                    if let track = service.nowPlayingTrack, track.title != nil || track.artist != nil {
                        LabeledContent("Now Playing", value: [track.artist, track.title].compactMap { $0 }.joined(separator: " — "))
                    }
                }
                if let lastError = service.lastError {
                    Text("\(lastError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AirPlay Receiver")
        .toolbar {
            ToolbarItemGroup {
                Button("Save") {
                    persist()
                }
            }
        }
        .alert("AirPlay Receiver Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func persist() {
        var updated = store.settings
        updated.enabled = mode.enabled
        updated.relayEnabled = mode.relayEnabled
        updated.deviceName = deviceName
        updated.destinationHost = destinationHost
        updated.destinationPort = destinationPort
        do {
            let saved = try store.save(updated)
            service.applySettings(saved)
        } catch {
            errorMessage = "\(error)"
        }
    }
}

#Preview {
    AirPlaySettingsView(settings: .fallback())
        .environment(AirPlaySettingsStore())
        .environment(AirPlayReceiverService())
}
