import Testing
import Foundation
@testable import ControlBooth

/// The USB tree built from the IORegistry (`ioreg -a`): locations in
/// uhubctl's notation, hubs' depth, which ports can be power cycled, and
/// which RTL-SDRs lose power with a port.
struct USBTreeTests {
    private func device(_ name: String, vendor: Int, product: Int, location: Int, deviceClass: Int = 0,
                        serial: String? = nil, children: [[String: Any]] = []) -> [String: Any] {
        var node: [String: Any] = ["IORegistryEntryName": name, "USB Product Name": name, "idVendor": vendor,
                                   "idProduct": product, "locationID": location, "bDeviceClass": deviceClass,
                                   "IORegistryEntryChildren": children]
        if let serial { node["USB Serial Number"] = serial }
        return node
    }

    /// A trimmed copy of this Mac's tree: a ppps hub (2-2.1) with a mouse and
    /// a ganged hub holding a cascaded hub with two RTL-SDRs.
    private var plist: Data {
        let rtl1 = device("RTL2838UHIDIR", vendor: 0x0bda, product: 0x2838, location: 0x2211442, serial: "00000180")
        let rtl2 = device("RTL2838UHIDIR", vendor: 0x0bda, product: 0x2838, location: 0x2211443, serial: "00000360")
        let cascade = device("USB2.1 Hub", vendor: 0x05e3, product: 0x0610, location: 0x2211440,
                             deviceClass: 9, children: [rtl1, rtl2])
        let mtt2 = device("USB 2.0 Hub [MTT]", vendor: 0x1a40, product: 0x0101, location: 0x2211400,
                          deviceClass: 9, children: [cascade])
        let mtt = device("USB 2.0 Hub [MTT]", vendor: 0x1a40, product: 0x0101, location: 0x2211000,
                         deviceClass: 9, children: [mtt2])
        let mouse = device("USB Optical Mouse", vendor: 0x093a, product: 0x2510, location: 0x2213000)
        let hub = device("Hub", vendor: 0x045b, product: 0x0209, location: 0x2210000,
                         deviceClass: 9, children: [mouse, mtt])
        let rootHub = device("Hub", vendor: 0x045b, product: 0x0209, location: 0x2200000,
                             deviceClass: 9, children: [hub])
        let controller: [String: Any] = ["IORegistryEntryName": "AppleEmbeddedUSBXHCIFL1100",
                                         "locationID": 0x2000000, "IORegistryEntryChildren": [rootHub]]
        let root: [String: Any] = ["IORegistryEntryName": "Root", "IORegistryEntryChildren": [controller]]
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private var hubs: [USBHub] {
        UhubctlParser.parse("""
            Current status for hub 2-2.1 [045b:0209, USB 2.10, 4 ports, ppps]
              Port 1: 0503 power highspeed enable connect [1a40:0101 USB 2.0 Hub [MTT], USB 2.00, 4 ports, ganged]
            """)
    }

    @Test func locationIDsBecomeUhubctlPaths() {
        #expect(USBTree.uhubctlPath(forLocationID: 0x02211442) == "2-2.1.1.4.4.2")
        #expect(USBTree.uhubctlPath(forLocationID: 0x02210000) == "2-2.1")
        #expect(USBTree.uhubctlPath(forLocationID: 0x02200000) == "2-2")
    }

    @Test func treeKeepsHierarchyAndDepth() {
        let rows = USBTree.rows(fromIORegPlist: plist, hubs: hubs)
        #expect(rows.map(\.path) == ["2-2", "2-2.1", "2-2.1.3", "2-2.1.1", "2-2.1.1.4", "2-2.1.1.4.4",
                                     "2-2.1.1.4.4.2", "2-2.1.1.4.4.3"])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 3, 4, 5, 5])
        #expect(rows[0].parentPath == nil)
    }

    @Test func onlyPortsOfAPerPortSwitchableHubAreSelectable() throws {
        let rows = USBTree.rows(fromIORegPlist: plist, hubs: hubs)
        let selectable = rows.filter(\.selectable).map(\.path)
        // Children of 2-2.1 (ppps): the mouse and the first MTT hub.
        #expect(selectable == ["2-2.1.3", "2-2.1.1"])
        let mtt = try #require(rows.first { $0.path == "2-2.1.1" })
        #expect(mtt.parentPath == "2-2.1" && mtt.port == 1 && mtt.parentUSBID == "045b:0209")
        #expect(mtt.usbID == "1a40:0101")
        // Without uhubctl nothing can be switched.
        #expect(USBTree.rows(fromIORegPlist: plist, hubs: []).allSatisfy { !$0.selectable })
    }

    @Test func rtlsdrsBelowAPortLosePowerWithIt() throws {
        let rows = USBTree.rows(fromIORegPlist: plist, hubs: hubs)
        let mtt = try #require(rows.first { $0.path == "2-2.1.1" })
        let radios = USBTree.rtlsdrs(affectedBy: mtt, in: rows)
        #expect(radios.map(\.serial) == ["00000180", "00000360"])
        #expect(radios.allSatisfy { $0.isRTLSDR })
        let mouse = try #require(rows.first { $0.path == "2-2.1.3" })
        #expect(USBTree.rtlsdrs(affectedBy: mouse, in: rows).isEmpty)
        #expect(USBTree.devices(affectedBy: mtt, in: rows).count == 5)
        // A path that merely starts with the same digits isn't below it.
        #expect(!USBTree.devices(affectedBy: mtt, in: rows).contains { $0.path == "2-2.1.3" })
    }
}
