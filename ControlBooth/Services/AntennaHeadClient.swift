import AppKit
import SharedLogging

/// ControlBooth's sending half of the AppleEvents control channel with
/// AntennaHead (see "AppleEvents control channel" in SETUP.md).
///
/// Event vocabulary — event class 'AntH':
///   'Strt'  start listening   direct parameter: custom-task name
///   'Stop'  stop listening    direct parameter: custom-task name
///   'Runs'  listening tasks   reply: list of the listening tasks' names
///   'RecS'  start recording   direct parameter: filename to create. Written
///                             into the Recordings folder of the App Group
///                             (`group.com.dsward.antennahead`) shared with
///                             AntennaHead, so only a filename is needed —
///                             the destination folder itself is fixed and
///                             not ControlBooth's to pick or send.
///                             optional 'Tone' parameter (boolean): when
///                             true, AntennaHead fills any gap in real audio
///                             with an audible test tone instead of silence,
///                             so a manual test recording is verifiable by
///                             ear even with no station tuned. Scheduled/live
///                             recordings omit it and get silence filler.
///   'RecP'  stop recording    no parameters
///
/// Sending waits synchronously for the reply (with a timeout), so call from
/// user-action contexts, not tight loops. The first send triggers macOS's
/// one-time Automation consent prompt ("ControlBooth wants access to control
/// AntennaHead").
enum AntennaHeadClient {
    static let bundleIdentifier = "com.dsward.AntennaHead"

    enum ClientError: Error, CustomStringConvertible {
        case notRunning
        case eventError(code: Int, message: String?)

        var description: String {
            switch self {
            case .notRunning:
                return "AntennaHead is not running."
            case .eventError(let code, let message):
                return message ?? "AntennaHead returned Apple Event error \(code)."
            }
        }
    }

    static var isAntennaHeadRunning: Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let message = "isAntennaHeadRunning — found \(apps.count) instance(s): \(apps.map { $0.processIdentifier })"
        Task { @MainActor in LogStore.shared.log(.info, source: "AntennaHeadClient", message) }
        return !apps.isEmpty
    }

    static func startListening(task name: String) throws {
        _ = try send(eventID: "Strt", directParameter: NSAppleEventDescriptor(string: name))
    }

    static func stopListening(task name: String) throws {
        _ = try send(eventID: "Stop", directParameter: NSAppleEventDescriptor(string: name))
    }

    static func startRecording(filename: String, useToneFiller: Bool = false) throws {
        var extraParams: [FourCharCode: NSAppleEventDescriptor] = [:]
        if useToneFiller {
            extraParams[keyUseToneFiller] = NSAppleEventDescriptor(boolean: true)
        }
        _ = try send(eventID: "RecS", directParameter: NSAppleEventDescriptor(string: filename),
                     extraParams: extraParams)
    }

    static func stopRecording() throws {
        _ = try send(eventID: "RecP", directParameter: nil)
    }

    static func listeningTasks() throws -> [String] {
        let reply = try send(eventID: "Runs", directParameter: nil)
        guard let list = reply.paramDescriptor(forKeyword: keyDirectObject),
              list.numberOfItems > 0 else {
            return []
        }
        // AEDesc list indices are 1-based.
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
    }

    private static func send(eventID: String, directParameter: NSAppleEventDescriptor?,
                              extraParams: [FourCharCode: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        // Use PID-based targeting so the event goes to exactly the running instance
        // we find, not an ambiguous bundle-ID lookup (which can hit a stale process).
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw ClientError.notRunning
        }
        let logMessage = "sending '\(eventID)' to AntennaHead PID \(app.processIdentifier)"
        Task { @MainActor in LogStore.shared.log(.info, source: "AntennaHeadClient", logMessage) }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC("AntH"),
            eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(-1),   // kAutoGenerateReturnID
            transactionID: AETransactionID(0)   // kAnyTransactionID
        )
        if let directParameter {
            event.setParam(directParameter, forKeyword: keyDirectObject)
        }
        for (keyword, descriptor) in extraParams {
            event.setParam(descriptor, forKeyword: keyword)
        }
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 8)
        if let errorNumber = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
           errorNumber != 0 {
            throw ClientError.eventError(
                code: Int(errorNumber),
                message: reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
            )
        }
        return reply
    }

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static let keyDirectObject = fourCC("----")
    private static let keyErrorNumber = fourCC("errn")
    private static let keyErrorString = fourCC("errs")
    private static let keyUseToneFiller = fourCC("Tone")
}
