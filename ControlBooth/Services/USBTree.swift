import Foundation

/// One USB device in the tree `ioreg` reports, in the order it is drawn.
nonisolated struct USBTreeRow: Identifiable, Equatable, Codable {
    var id: String { path }
    /// The device's place in uhubctl's notation: bus, then the port numbers
    /// from the root hub down, e.g. "2-2.1.1" is port 1 of hub "2-2.1".
    var path: String
    /// How many hubs deep this device is.
    var depth: Int
    var name: String
    /// "vendor:product" in lower-case hex, e.g. "0bda:2838".
    var usbID: String
    /// The USB serial number; for an RTL-SDR the EEPROM serial.
    var serial: String
    var isHub: Bool
    var isRTLSDR: Bool
    /// The hub this device is plugged into and its port there; nil for a root hub.
    var parentPath: String?
    var parentUSBID: String?
    var port: Int?
    /// True when the hub it is plugged into can switch this port's power on
    /// its own (uhubctl's `ppps`), so this is something that can be power cycled.
    var selectable: Bool
}

/// Builds the USB tree from the IORegistry (`ioreg -a -p IOUSB -l`), marking
/// which ports `uhubctl` can switch.
nonisolated enum USBTree {
    /// Reads the live tree. `hubs` is uhubctl's listing, empty when it isn't installed.
    static func readRows(hubs: [USBHub]) throws -> [USBTreeRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-a", "-p", "IOUSB", "-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw USBHubPowerError.failed("could not run ioreg: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw USBHubPowerError.failed("ioreg failed (status \(process.terminationStatus))")
        }
        return rows(fromIORegPlist: data, hubs: hubs)
    }

    /// `data` is the property list `ioreg -a` writes.
    static func rows(fromIORegPlist data: Data, hubs: [USBHub]) -> [USBTreeRow] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        var rows: [USBTreeRow] = []
        walk(root, depth: 0, parent: nil, hubs: hubs, into: &rows)
        return rows
    }

    private struct Parent {
        var path: String
        var usbID: String
        var switchesPorts: Bool
    }

    private static func walk(_ node: [String: Any], depth: Int, parent: Parent?, hubs: [USBHub],
                             into rows: inout [USBTreeRow]) {
        let children = node["IORegistryEntryChildren"] as? [[String: Any]] ?? []
        // Host controllers and other registry entries aren't devices (they
        // have no vendor ID); their children are.
        guard let vendor = node["idVendor"] as? Int, let product = node["idProduct"] as? Int,
              let location = node["locationID"] as? Int else {
            for child in children { walk(child, depth: depth, parent: parent, hubs: hubs, into: &rows) }
            return
        }
        let usbID = String(format: "%04x:%04x", vendor, product)
        let path = uhubctlPath(forLocationID: UInt32(truncatingIfNeeded: location))
        let isHub = (node["bDeviceClass"] as? Int) == 9
        let name = (node["USB Product Name"] as? String) ?? (node["kUSBProductString"] as? String)
            ?? (isHub ? "USB Hub" : "USB Device")
        let isRTL = vendor == 0x0bda && [0x2832, 0x2838].contains(product) || name.hasPrefix("RTL28")
        rows.append(USBTreeRow(
            path: path, depth: depth, name: name, usbID: usbID,
            serial: (node["USB Serial Number"] as? String) ?? "",
            isHub: isHub, isRTLSDR: isRTL,
            parentPath: parent?.path, parentUSBID: parent?.usbID,
            port: parent == nil ? nil : Int(path.split(separator: ".").last ?? ""),
            selectable: parent?.switchesPorts ?? false))
        let hub = hubs.first { $0.location == path && $0.usbID == usbID }
        let me = Parent(path: path, usbID: usbID, switchesPorts: hub?.switchesPerPort ?? false)
        for child in children { walk(child, depth: depth + 1, parent: me, hubs: hubs, into: &rows) }
    }

    /// macOS packs a device's route into its location ID: the bus in the top
    /// byte, then one nibble per hub port ("0x02211442" is bus 2, ports
    /// 2.1.1.4.4.2). uhubctl writes that "2-2.1.1.4.4.2".
    static func uhubctlPath(forLocationID location: UInt32) -> String {
        let bus = location >> 24
        var ports: [String] = []
        for shift in stride(from: 20, through: 0, by: -4) {
            let nibble = (location >> UInt32(shift)) & 0xF
            if nibble == 0 { break }
            ports.append(String(nibble))
        }
        return ports.isEmpty ? "\(bus)-0" : "\(bus)-\(ports.joined(separator: "."))"
    }

    /// The RTL-SDRs at or below `row`: what loses power with it.
    static func rtlsdrs(affectedBy row: USBTreeRow, in rows: [USBTreeRow]) -> [USBTreeRow] {
        rows.filter { $0.isRTLSDR && ($0.path == row.path || $0.path.hasPrefix(row.path + ".")) }
    }

    /// Everything at or below `row`.
    static func devices(affectedBy row: USBTreeRow, in rows: [USBTreeRow]) -> [USBTreeRow] {
        rows.filter { $0.path == row.path || $0.path.hasPrefix(row.path + ".") }
    }
}
