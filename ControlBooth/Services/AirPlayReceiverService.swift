import Foundation
import Observation
import AirPlayReceiver
import SharedLogging

/// Thin wrapper owning the single AirPlayReceiverController instance,
/// applying ControlBooth's persisted AirPlaySettings to it. Unlike Pipeline
/// records (user-assembled, manually started chains), the AirPlay receiver is
/// a standalone always-advertising background service — this class just
/// starts/stops/updates it in response to the settings toggle.
@MainActor
@Observable
final class AirPlayReceiverService {
    private let controller: AirPlayReceiverController

    var isRunning: Bool { controller.isRunning }
    var lastError: Error? { controller.lastError }

    init() {
        controller = AirPlayReceiverController(configuration: AirPlayReceiverService.makeConfiguration(from: .fallback()))
        controller.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
    }

    func stopAll() {
        controller.stop()
    }

    func applySettings(_ settings: AirPlaySettings) {
        let configuration = Self.makeConfiguration(from: settings)
        if settings.enabled {
            controller.updateConfiguration(configuration)
            if !controller.isRunning {
                controller.start()
            }
        } else {
            controller.stop()
        }
    }

    private static func makeConfiguration(from settings: AirPlaySettings) -> AirPlayReceiverController.Configuration {
        AirPlayReceiverController.Configuration(
            deviceName: settings.deviceName,
            udpHost: settings.destinationHost,
            udpPort: UInt16(clamping: settings.destinationPort)
        )
    }
}
