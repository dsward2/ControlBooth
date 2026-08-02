import Foundation

/// The App Group container ControlBooth and AntennaHead share for
/// ControlBooth-triggered ('RecS'/'RecP' AppleEvent) and LiveAudioServer
/// tab recordings — mirrors AntennaHead's own `SharedRecordingFolder`
/// (same App Group identifier, same "Recordings" subfolder) so both apps
/// resolve to the identical fixed folder without a picker or bookmark.
enum SharedRecordingFolder {
    static let appGroupIdentifier = "group.com.dsward.antennahead"

    /// Creates the folder on first access if it doesn't exist yet. `nil`
    /// only if the App Group entitlement itself is missing or misconfigured.
    static var url: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let folder = container.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
