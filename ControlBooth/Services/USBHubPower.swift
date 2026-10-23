import Foundation
import SDRDeviceAccess

/// Which upstream USB hub port to power cycle when an RTL-SDR wedges.
///
/// A wedged RTL-SDR ("PLL not locked", no samples) only recovers when it is
/// unplugged. When the dongles sit on a hub that can't switch its own ports
/// (`ganged` power), the hub one level up often can: cutting its port cuts the
/// downstream hub and every dongle on it, like replugging that hub.
nonisolated struct USBHubPowerSettings: Codable, Equatable {
    var enabled = false
    /// uhubctl's hub location, e.g. "2-2.1".
    var hubLocation = ""
    /// The hub's USB ID ("045b:0209"). Checked before every cycle so a
    /// changed USB topology can't make this switch off some other hub.
    var hubID = ""
    var port = 0
    /// The ID of the device on that port ("1a40:0101", the downstream hub),
    /// checked the same way. Empty skips the check.
    var portDeviceID = ""
    /// Seconds the port stays off.
    var offSeconds = 3

    var isConfigured: Bool { !hubLocation.isEmpty && !hubID.isEmpty && port > 0 }

    static let defaultsKey = "usbHubPower.settings"

    static func load(from defaults: UserDefaults = .standard) -> USBHubPowerSettings {
        guard let json = defaults.string(forKey: defaultsKey),
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(USBHubPowerSettings.self, from: data) else {
            return USBHubPowerSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}

/// A hub as `uhubctl` lists it.
nonisolated struct USBHub: Equatable, Identifiable {
    struct Port: Equatable {
        var number: Int
        /// The USB ID of what's plugged in, nil when the port is empty or off.
        var deviceID: String?
        var deviceName: String?
    }

    var location: String
    var id: String { location }
    /// "045b:0209".
    var usbID: String
    var portCount: Int
    /// uhubctl's `ppps`: each port's power can be switched on its own. A
    /// `ganged` hub switches all its ports together.
    var switchesPerPort: Bool
    var ports: [Port]

    func port(_ number: Int) -> Port? { ports.first { $0.number == number } }
}

/// Reads `uhubctl`'s listing, e.g.
///
///     Current status for hub 2-2.1 [045b:0209, USB 2.10, 4 ports, ppps]
///       Port 1: 0503 power highspeed enable connect [1a40:0101 USB 2.0 Hub [MTT], USB 2.00, 4 ports, ganged]
///       Port 3: 0100 power
nonisolated enum UhubctlParser {
    static func parse(_ output: String) -> [USBHub] {
        var hubs: [USBHub] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let hub = parseHub(line) {
                hubs.append(hub)
            } else if let port = parsePort(line), !hubs.isEmpty {
                hubs[hubs.count - 1].ports.append(port)
            }
        }
        return hubs
    }

    private static func parseHub(_ line: String) -> USBHub? {
        guard line.hasPrefix("Current status for hub ") else { return nil }
        let rest = line.dropFirst("Current status for hub ".count)
        guard let space = rest.firstIndex(of: " "),
              let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]") else { return nil }
        let location = String(rest[..<space])
        let fields = rest[rest.index(after: open)..<close].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // A hub that isn't a root hub names itself after its ID: "1a40:0101 USB 2.0 Hub [MTT]".
        guard let first = fields.first, first.count >= 9 else { return nil }
        let usbID = String(first.prefix(9))
        guard usbID.dropFirst(4).first == ":" else { return nil }
        let ports = fields.compactMap { field -> Int? in
            guard field.hasSuffix(" ports") else { return nil }
            return Int(field.dropLast(" ports".count))
        }.first ?? 0
        return USBHub(location: location, usbID: usbID, portCount: ports,
                      switchesPerPort: fields.contains("ppps"), ports: [])
    }

    private static func parsePort(_ line: String) -> USBHub.Port? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Port "), let colon = trimmed.firstIndex(of: ":"),
              let number = Int(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<colon]) else { return nil }
        var port = USBHub.Port(number: number)
        // The attached device is the first "[vid:pid name, ...]" group.
        if let open = trimmed.firstIndex(of: "[") {
            let inside = trimmed[trimmed.index(after: open)...]
            let id = inside.prefix(9)
            if id.count == 9, id.dropFirst(4).first == ":" {
                port.deviceID = String(id)
                var name = String(inside.dropFirst(10))
                if let end = name.range(of: ", USB ") { name = String(name[..<end.lowerBound]) }
                name = name.trimmingCharacters(in: .whitespaces)
                // A lone device's group ends with the closing bracket.
                if name.hasSuffix("]"), !name.contains("[") { name.removeLast() }
                port.deviceName = name.isEmpty ? nil : name
            }
        }
        return port
    }
}

nonisolated enum USBHubPowerError: Error, CustomStringConvertible {
    case uhubctlMissing
    case notConfigured
    case hubNotFound(location: String)
    case hubChanged(location: String, found: String, expected: String)
    case portNotSwitchable(location: String)
    case portDeviceChanged(port: Int, found: String?, expected: String)
    case failed(String)

    var description: String {
        switch self {
        case .uhubctlMissing:
            return "uhubctl isn't installed. Install it with MacPorts (sudo port install uhubctl) or Homebrew (brew install uhubctl)."
        case .notConfigured:
            return "No upstream hub and port are chosen for power cycling."
        case .hubNotFound(let location):
            return "No USB hub at \(location). The USB layout changed: choose the hub again."
        case .hubChanged(let location, let found, let expected):
            return "The hub at \(location) is now \(found), not \(expected). The USB layout changed: choose the hub again."
        case .portNotSwitchable(let location):
            return "The hub at \(location) can't switch its ports' power individually."
        case .portDeviceChanged(let port, let found, let expected):
            return "Port \(port) now has \(found ?? "nothing") instead of \(expected). The USB layout changed: choose the hub again."
        case .failed(let message):
            return message
        }
    }
}

/// Runs `uhubctl`, which switches the power of a hub's ports.
nonisolated struct USBHubPowerCycler {
    /// Where uhubctl is installed, the first that exists.
    static let searchPaths = [
        "/opt/local/sbin/uhubctl", "/opt/local/bin/uhubctl",
        "/opt/homebrew/sbin/uhubctl", "/opt/homebrew/bin/uhubctl",
        "/usr/local/sbin/uhubctl", "/usr/local/bin/uhubctl",
    ]

    var executable: String?

    init(executable: String? = Self.searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.executable = executable
    }

    var isInstalled: Bool { executable != nil }

    /// Every hub uhubctl can see, with what's plugged into each port.
    func listHubs() throws -> [USBHub] {
        UhubctlParser.parse(try run([]))
    }

    /// Checks `settings` still names the hub and device it was set up for.
    /// Returns the command-line arguments that cycle the port.
    func validatedCycleArguments(for settings: USBHubPowerSettings, hubs: [USBHub]) throws -> [String] {
        guard settings.isConfigured else { throw USBHubPowerError.notConfigured }
        guard let hub = hubs.first(where: { $0.location == settings.hubLocation }) else {
            throw USBHubPowerError.hubNotFound(location: settings.hubLocation)
        }
        guard hub.usbID == settings.hubID else {
            throw USBHubPowerError.hubChanged(location: hub.location, found: hub.usbID, expected: settings.hubID)
        }
        guard hub.switchesPerPort else { throw USBHubPowerError.portNotSwitchable(location: hub.location) }
        if !settings.portDeviceID.isEmpty {
            let found = hub.port(settings.port)?.deviceID
            guard found == settings.portDeviceID else {
                throw USBHubPowerError.portDeviceChanged(port: settings.port, found: found,
                                                          expected: settings.portDeviceID)
            }
        }
        return ["-l", hub.location, "-p", String(settings.port),
                "-a", "cycle", "-d", String(max(1, settings.offSeconds))]
    }

    /// Cuts power to the chosen port and restores it (uhubctl also cycles a
    /// USB 3 companion port when the hub has one). Blocks for the off time
    /// plus a moment. Returns uhubctl's report.
    @discardableResult
    func cycle(_ settings: USBHubPowerSettings) throws -> String {
        let arguments = try validatedCycleArguments(for: settings, hubs: try listHubs())
        return try run(arguments)
    }

    private func run(_ arguments: [String]) throws -> String {
        guard let executable else { throw USBHubPowerError.uhubctlMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw USBHubPowerError.failed("could not run uhubctl: \(error)")
        }
        // Read before waiting, so a full pipe can't block uhubctl.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw USBHubPowerError.failed("uhubctl failed (status \(process.terminationStatus))"
                                          + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return output
    }
}

/// Brings a wedged RTL-SDR back by power cycling the hub port in
/// `USBHubPowerSettings`, then waiting for the dongle to reappear.
nonisolated enum USBHubRecovery {
    /// How long to wait for the dongle to re-enumerate after the power returns.
    static let reappearTimeout: TimeInterval = 40

    /// The recovery to give the scanner, or nil when power cycling is off or
    /// no hub port has been chosen.
    static func recovery(for settings: USBHubPowerSettings)
        -> (@Sendable (String) async -> DsdNeoScanner.HardwareRecoveryResult)? {
        guard settings.enabled, settings.isConfigured else { return nil }
        return { serial in await powerCycleAndWait(forSerial: serial, settings: settings) }
    }

    static func powerCycleAndWait(forSerial serial: String,
                                  settings: USBHubPowerSettings = .load(),
                                  cycler: USBHubPowerCycler = USBHubPowerCycler()) async
        -> DsdNeoScanner.HardwareRecoveryResult {
        await Task.detached(priority: .userInitiated) {
            do {
                try cycler.cycle(settings)
            } catch {
                return .failed("\(error)")
            }
            // Hubs and dongles take a few seconds to enumerate; the dongle's
            // USB index can differ from before, so it's found again by serial.
            let deadline = Date().addingTimeInterval(reappearTimeout)
            Thread.sleep(forTimeInterval: 3)
            while Date() < deadline {
                let report = RTLSDRPreflight.check(device: serial, backend: LibRTLSDRBackend())
                if report.isAvailable, let index = report.index { return .recovered(index: index) }
                Thread.sleep(forTimeInterval: 1)
            }
            return .failed("The RTL-SDR (\(serial)) did not come back within \(Int(reappearTimeout)) seconds "
                           + "of the hub's power returning.")
        }.value
    }
}
