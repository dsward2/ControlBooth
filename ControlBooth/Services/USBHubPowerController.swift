import Foundation
import SharedLogging
import Observation

/// What `usb hub status` tells AntennaHead (JSON).
nonisolated struct USBHubPowerStatus: Codable, Equatable {
    var uhubctlInstalled: Bool
    /// Automatic recovery is on in the dsd-neo Scanner's settings.
    var enabled: Bool
    /// A hub port is chosen for power cycling.
    var configured: Bool
    /// "Hub 2-2.1, port 1: USB 2.0 Hub [MTT]", empty when not configured.
    var target: String
    /// RTL-SDR serials that lose power with that port.
    var affectedRTLSDRs: [String]
    var cycling: Bool
    /// The outcome of the last power cycle, empty before any.
    var message: String
    var messageIsError: Bool
    /// Included when asked for.
    var tree: [USBTreeRow]?
    /// The tree path of the chosen port's device ("2-2.1.1"), empty when none
    /// is chosen or it isn't in the tree.
    var selectedPath: String = ""
}

/// The USB tree, the chosen hub port and power cycling it: shared by the USB
/// Tree window, the Commands menu, the dsd-neo Scanner's settings and the
/// AppleEvents AntennaHead's web page uses.
@MainActor
@Observable
final class USBHubPowerController {
    var settings: USBHubPowerSettings {
        didSet { if settings != oldValue { settings.save() } }
    }
    private(set) var rows: [USBTreeRow] = []
    private(set) var hubs: [USBHub] = []
    private(set) var isCycling = false
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var listingError: String?
    /// Set by Commands > Power Cycle USB Hub…; the USB Tree window asks the
    /// user to confirm and clears it.
    var confirmationRequested = false

    @ObservationIgnored let cycler: USBHubPowerCycler

    init(settings: USBHubPowerSettings = .load(), cycler: USBHubPowerCycler = USBHubPowerCycler()) {
        self.settings = settings
        self.cycler = cycler
    }

    var uhubctlInstalled: Bool { cycler.isInstalled }

    /// The tree row for the chosen port, when it's in the tree.
    var selectedRow: USBTreeRow? {
        guard settings.isConfigured else { return nil }
        return rows.first { $0.parentPath == settings.hubLocation && $0.port == settings.port }
    }

    /// RTL-SDRs that lose power with the chosen port.
    var affectedRTLSDRs: [USBTreeRow] {
        selectedRow.map { USBTree.rtlsdrs(affectedBy: $0, in: rows) } ?? []
    }

    /// Everything that loses power with the chosen port.
    var affectedDevices: [USBTreeRow] {
        selectedRow.map { USBTree.devices(affectedBy: $0, in: rows) } ?? []
    }

    var targetDescription: String {
        guard settings.isConfigured else { return "" }
        let name = selectedRow?.name ?? settings.portDeviceID
        return "Hub \(settings.hubLocation), port \(settings.port): \(name)"
    }

    var canCycle: Bool { settings.isConfigured && cycler.isInstalled && !isCycling }

    /// When the tree was last read; nil before the first read.
    @ObservationIgnored private var lastRefresh: Date?

    /// How long a read of the tree is good for when a status is asked for.
    static let statusMaxAge: TimeInterval = 10

    /// Reads the tree unless it was read within `maxAge` seconds, so a status
    /// poll names the chosen port and its RTL-SDRs without launching ioreg and
    /// uhubctl on every request.
    func refreshIfStale(maxAge: TimeInterval = USBHubPowerController.statusMaxAge) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    /// Reads the tree and uhubctl's hub list again.
    func refresh() {
        lastRefresh = Date()
        let cycler = self.cycler
        do {
            let hubs = cycler.isInstalled ? try cycler.listHubs() : []
            let rows = try USBTree.readRows(hubs: hubs)
            self.hubs = hubs
            self.rows = rows
            listingError = nil
        } catch {
            listingError = "\(error)"
        }
    }

    /// Chooses `row`, a device on a switchable hub, as what to power cycle.
    func select(_ row: USBTreeRow) {
        guard row.selectable, let parent = row.parentPath, let parentID = row.parentUSBID, let port = row.port else {
            return
        }
        settings.hubLocation = parent
        settings.hubID = parentID
        settings.port = port
        settings.portDeviceID = row.usbID
    }

    /// Chooses the tree row at `path` (as the 'select usb hub port' command
    /// and AntennaHead's web page name it); throws when it isn't there or its
    /// hub can't switch its power.
    func select(path: String) throws {
        guard let row = rows.first(where: { $0.path == path }) else {
            throw USBHubPowerError.failed("No USB device is at \(path); refresh the tree.")
        }
        guard row.selectable else {
            throw USBHubPowerError.failed("The hub above \(row.name) can't switch its port's power.")
        }
        select(row)
    }

    /// Starts a power cycle of the chosen port in the background; throws when
    /// it can't be started. The outcome lands in `message`. `completion` runs
    /// on the main actor once it finishes.
    func startCycle(completion: (@MainActor (Bool) -> Void)? = nil) throws {
        guard settings.isConfigured else { throw USBHubPowerError.notConfigured }
        guard cycler.isInstalled else { throw USBHubPowerError.uhubctlMissing }
        guard !isCycling else { throw USBHubPowerError.failed("A power cycle is already running.") }
        isCycling = true
        message = nil
        let settings = self.settings, cycler = self.cycler
        let target = targetDescription
        LogStore.shared.log(.warning, source: "USBHubPower", "power cycling \(target)")
        Task {
            let result = await Task.detached { Result { try cycler.cycle(settings) } }.value
            isCycling = false
            switch result {
            case .success:
                message = "Power cycled \(target)."
                messageIsError = false
            case .failure(let error):
                message = "\(error)"
                messageIsError = true
                LogStore.shared.log(.error, source: "USBHubPower", "power cycle failed: \(error)")
            }
            // The devices come back over the next few seconds.
            try? await Task.sleep(for: .seconds(5))
            refresh()
            completion?(!messageIsError)
        }
    }

    func status(includingTree: Bool) -> USBHubPowerStatus {
        USBHubPowerStatus(
            uhubctlInstalled: uhubctlInstalled, enabled: settings.enabled, configured: settings.isConfigured,
            target: targetDescription,
            affectedRTLSDRs: affectedRTLSDRs.map { $0.serial.isEmpty ? $0.name : $0.serial },
            cycling: isCycling, message: message ?? "", messageIsError: messageIsError,
            tree: includingTree ? rows : nil, selectedPath: selectedRow?.path ?? "")
    }
}
