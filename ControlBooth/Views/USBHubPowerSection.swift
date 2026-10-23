import SwiftUI

/// Form section for automatic power cycling of an upstream USB hub when an
/// RTL-SDR wedges. The port is chosen in the USB Tree window; the choice
/// belongs to the hardware, not to a scanner configuration, so it saves as it
/// changes.
struct USBHubPowerSection: View {
    @Environment(USBHubPowerController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var controller = controller
        Section {
            Toggle("Power cycle a USB hub if the RTL-SDR wedges", isOn: $controller.settings.enabled)
            if controller.settings.enabled {
                LabeledContent("Hub Port") {
                    Text(controller.settings.isConfigured ? controller.targetDescription : "None chosen")
                        .foregroundStyle(controller.settings.isConfigured ? .primary : .secondary)
                }
                HStack {
                    Spacer()
                    Button("USB Tree…") { openWindow(id: "usb-tree") }
                        .controlSize(.small)
                }
                if !controller.uhubctlInstalled {
                    Label(String(describing: USBHubPowerError.uhubctlMissing), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("USB Hub Power")
        } footer: {
            Text("A wedged RTL-SDR only recovers when it loses power. If your RTL-SDRs are on a hub that can't "
                 + "switch its own ports, choose (in the USB Tree) the port of the hub above it that the "
                 + "RTL-SDR hub is plugged into. When the scanner gets no signal after restarting, that port "
                 + "is switched off and on, which drops everything on the hub below for a few seconds. "
                 + "Applies the next time the scanner starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
