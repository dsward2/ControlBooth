import Foundation
import Network

/// Sends live spatial-audio control messages to a running `PCMDistanceGain`
/// or `PCMBinauralPanner` stage's UDP control port — same wire format both
/// tools' own doc comments describe (`nc -u` can send the identical
/// commands by hand), same fire-and-forget pattern AntennaHead's
/// `SDRController` uses for its own copies of these stages. Harmless if
/// nothing is listening on the port.
enum SpatialControlSender {
    static func sendDistance(_ distance: Double, toPort port: UInt16) {
        send("dist \(distance)\n", toPort: port)
    }

    static func sendPosition(azimuth: Double, elevation: Double, toPort port: UInt16) {
        send("pos \(azimuth) \(elevation)\n", toPort: port)
    }

    private static func send(_ message: String, toPort port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .udp)
        connection.start(queue: .main)
        connection.send(content: Data(message.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
