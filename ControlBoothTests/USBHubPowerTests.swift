import Testing
import Foundation
@testable import ControlBooth

/// The USB hub power cycle: reading uhubctl's listing and refusing to cycle a
/// hub or port that isn't the one the user chose. The listing is verbatim
/// from uhubctl on macOS.
struct USBHubPowerTests {
    static let listing = """
        Current status for hub 2-2.1 [045b:0209, USB 2.10, 4 ports, ppps]
          Port 1: 0503 power highspeed enable connect [1a40:0101 USB 2.0 Hub [MTT], USB 2.00, 4 ports, ganged]
          Port 2: 0103 power enable connect [077d:07af Griffin Technology, Inc iMic USB audio system]
          Port 3: 0100 power
        Current status for hub 2-5 [1a40:0101 USB 2.0 Hub [MTT], USB 2.00, 4 ports, ganged]
          Port 1: 0503 power highspeed enable connect [0bda:2838 RTL2838UHIDIR]
        """

    @Test func parsesHubsAndPorts() throws {
        let hubs = UhubctlParser.parse(Self.listing)
        #expect(hubs.count == 2)
        let hub = try #require(hubs.first)
        #expect(hub.location == "2-2.1")
        #expect(hub.usbID == "045b:0209")
        #expect(hub.portCount == 4)
        #expect(hub.switchesPerPort)
        #expect(hub.ports.count == 3)
        #expect(hub.port(1)?.deviceID == "1a40:0101")
        #expect(hub.port(1)?.deviceName == "USB 2.0 Hub [MTT]")
        #expect(hub.port(2)?.deviceName == "Griffin Technology, Inc iMic USB audio system")
        #expect(hub.port(3)?.deviceID == nil)
        #expect(hubs[1].switchesPerPort == false)
    }

    @Test func cycleArgumentsForTheChosenPort() throws {
        let settings = USBHubPowerSettings(enabled: true, hubLocation: "2-2.1", hubID: "045b:0209",
                                           port: 1, portDeviceID: "1a40:0101", offSeconds: 5)
        let arguments = try USBHubPowerCycler(executable: nil)
            .validatedCycleArguments(for: settings, hubs: UhubctlParser.parse(Self.listing))
        #expect(arguments == ["-l", "2-2.1", "-p", "1", "-a", "cycle", "-d", "5"])
    }

    @Test func refusesWhenTheTopologyChanged() {
        let hubs = UhubctlParser.parse(Self.listing)
        let cycler = USBHubPowerCycler(executable: nil)
        var settings = USBHubPowerSettings(enabled: true, hubLocation: "2-2.1", hubID: "045b:0209",
                                           port: 1, portDeviceID: "1a40:0101")

        settings.hubLocation = "9-9"
        #expect(throws: USBHubPowerError.self) { try cycler.validatedCycleArguments(for: settings, hubs: hubs) }

        settings.hubLocation = "2-2.1"
        settings.hubID = "dead:beef"     // another hub moved into that slot
        #expect(throws: USBHubPowerError.self) { try cycler.validatedCycleArguments(for: settings, hubs: hubs) }

        settings.hubID = "045b:0209"
        settings.port = 2                // a different device is on the port
        #expect(throws: USBHubPowerError.self) { try cycler.validatedCycleArguments(for: settings, hubs: hubs) }

        settings.port = 1
        #expect(throws: USBHubPowerError.self) {   // a ganged hub can't switch one port
            try cycler.validatedCycleArguments(
                for: USBHubPowerSettings(enabled: true, hubLocation: "2-5", hubID: "1a40:0101", port: 1),
                hubs: hubs)
        }
    }

    @Test func settingsRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "USBHubPowerTests-\(UUID().uuidString)"))
        #expect(USBHubPowerSettings.load(from: defaults) == USBHubPowerSettings())
        let settings = USBHubPowerSettings(enabled: true, hubLocation: "2-2.1", hubID: "045b:0209",
                                           port: 1, portDeviceID: "1a40:0101", offSeconds: 4)
        settings.save(to: defaults)
        #expect(USBHubPowerSettings.load(from: defaults) == settings)
        #expect(settings.isConfigured)
        #expect(!USBHubPowerSettings().isConfigured)
    }
}
