import Foundation
import GRDB

/// Single-row settings for the standalone AirPlay receiver service (not a
/// user-assembled Pipeline — it's an always-advertising background service
/// toggled on/off, so it gets its own fixed-id settings row rather than a
/// Pipeline record).
struct AirPlaySettings: Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    /// Always 1 — this table only ever holds one row.
    static let singletonID: Int64 = 1

    var id: Int64
    var enabled: Bool
    var deviceName: String
    var destinationHost: String
    var destinationPort: Int

    static let databaseTableName = "airplay_receiver_settings"

    enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case deviceName = "device_name"
        case destinationHost = "destination_host"
        case destinationPort = "destination_port"
    }

    static func fallback() -> AirPlaySettings {
        AirPlaySettings(
            id: singletonID,
            enabled: false,
            deviceName: "ControlBooth",
            destinationHost: "127.0.0.1",
            destinationPort: 6019
        )
    }
}
