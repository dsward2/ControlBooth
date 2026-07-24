import SwiftUI

struct AirPlaySettingsView: View {
    @Environment(AirPlaySettingsStore.self) private var store
    @Environment(AirPlayReceiverService.self) private var service

    @State private var enabled: Bool
    @State private var deviceName: String
    @State private var destinationHost: String
    @State private var destinationPort: Int
    @State private var errorMessage: String?

    init(settings: AirPlaySettings) {
        _enabled = State(initialValue: settings.enabled)
        _deviceName = State(initialValue: settings.deviceName)
        _destinationHost = State(initialValue: settings.destinationHost)
        _destinationPort = State(initialValue: settings.destinationPort)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable AirPlay Receiver", isOn: $enabled)
                TextField("Device Name", text: $deviceName)
                TextField("Destination Host", text: $destinationHost)
                TextField("Destination Port", value: $destinationPort, format: .number.grouping(.never))
            } header: {
                Text("AirPlay Receiver")
            } footer: {
                Text("When enabled, ControlBooth advertises itself as an AirPlay speaker named \"\(deviceName)\" and forwards decoded PCM audio to \(destinationHost):\(String(destinationPort)). Requires macOS's own built-in AirPlay Receiver (System Settings → General → AirDrop & Handoff) to be turned off, since both use RTSP port 5000.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Status", value: service.isRunning ? "Running" : "Stopped")
                if let lastError = service.lastError {
                    Text("\(lastError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AirPlay")
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
        updated.enabled = enabled
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
