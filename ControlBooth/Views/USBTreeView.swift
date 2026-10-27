import SwiftUI

/// The "USB Tree" window: every USB device with its hubs indented beneath
/// each other, the RTL-SDRs among them. Ports of hubs that can switch their
/// power are selectable (the choice is what gets power cycled when an
/// RTL-SDR wedges); everything else is dimmed.
struct USBTreeView: View {
    @Environment(USBHubPowerController.self) private var controller
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if controller.rows.isEmpty {
                ContentUnavailableView("No USB Devices", systemImage: "cable.connector",
                                       description: Text(controller.listingError ?? "Click Refresh to read the USB tree."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.rows) { row in
                        rowView(row)
                    }
                }
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            controller.refresh()
            if controller.confirmationRequested { present() }
        }
        .onChange(of: controller.confirmationRequested) { _, requested in
            if requested { present() }
        }
        .confirmationDialog("Power cycle \(controller.targetDescription)?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Power Cycle", role: .destructive) { cycle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    private func present() {
        controller.confirmationRequested = false
        if controller.canCycle { confirming = true }
    }

    private var confirmationText: String {
        let devices = controller.affectedDevices
        let radios = controller.affectedRTLSDRs.map { $0.serial.isEmpty ? $0.name : $0.serial }
        var text = "\(devices.count) device(s) lose power for \(controller.settings.offSeconds) seconds"
        if !radios.isEmpty { text += ", including RTL-SDR \(radios.joined(separator: ", "))" }
        return text + ". Anything using them stops receiving."
    }

    private func cycle() {
        do {
            try controller.startCycle()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't power cycle"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @ViewBuilder
    private func rowView(_ row: USBTreeRow) -> some View {
        let isChosen = controller.settings.isConfigured
            && row.parentPath == controller.settings.hubLocation && row.port == controller.settings.port
        HStack(spacing: 6) {
            Image(systemName: isChosen ? "largecircle.fill.circle" : (row.selectable ? "circle" : "minus.circle"))
                .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                .frame(width: 18)
            Image(systemName: row.isRTLSDR ? "antenna.radiowaves.left.and.right"
                  : (row.isHub ? "square.grid.2x2" : "cable.connector"))
                .frame(width: 18)
            Text(row.name).fontWeight(row.isHub ? .semibold : .regular)
            if !row.serial.isEmpty {
                Text(row.serial).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if row.isHub {
                Label(row.switchesPorts ? "per-port power" : "no per-port power",
                      systemImage: row.switchesPorts ? "bolt.fill" : "bolt.slash")
                    .font(.caption2)
                    .foregroundStyle(row.switchesPorts ? Color.green : .secondary)
                    .help(row.switchesPorts
                          ? "uhubctl can switch each port of this hub on its own (ppps)."
                          : "uhubctl can't switch this hub's ports individually (ganged, or not listed).")
            }
            Spacer()
            if let port = row.port, let parent = row.parentPath {
                Text("\(parent) port \(port)").font(.caption).foregroundStyle(.secondary)
            }
            Text(row.usbID).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .opacity(row.selectable ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { controller.select(row) }
        .help(row.selectable
              ? "Choose this port to power cycle"
              : "Its hub can't switch this port's power. Choose the hub above it that can.")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.uhubctlInstalled, !controller.rows.isEmpty, !controller.rows.contains(where: \.selectable) {
                Label("No hub here can switch its ports' power individually. " + USBHubRequirements.summary,
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.uhubctlInstalled {
                Label(String(describing: USBHubPowerError.uhubctlMissing), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if controller.settings.isConfigured {
                    Text("Power cycle: \(controller.targetDescription)").font(.callout)
                } else {
                    Text("Select a port of a hub that can switch power.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isCycling { ProgressView().controlSize(.small) }
                Button("Refresh") { controller.refresh() }
                Button("Power Cycle Now…") { confirming = true }
                    .disabled(!controller.canCycle)
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(controller.messageIsError ? .red : .secondary)
            }
        }
    }
}
