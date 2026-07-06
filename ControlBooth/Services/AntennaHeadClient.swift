import AppKit

/// ControlBooth's sending half of the AppleEvents control channel with
/// AntennaHead (see "AppleEvents control channel" in SETUP.md).
///
/// Event vocabulary — event class 'AntH':
///   'Strt'  start listening   direct parameter: custom-task name
///   'Stop'  stop listening    direct parameter: custom-task name
///   'Runs'  listening tasks   reply: list of the listening tasks' names
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
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func startListening(task name: String) throws {
        _ = try send(eventID: "Strt", directParameter: NSAppleEventDescriptor(string: name))
    }

    static func stopListening(task name: String) throws {
        _ = try send(eventID: "Stop", directParameter: NSAppleEventDescriptor(string: name))
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

    private static func send(eventID: String, directParameter: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard isAntennaHeadRunning else {
            throw ClientError.notRunning
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC("AntH"),
            eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier),
            returnID: AEReturnID(-1),   // kAutoGenerateReturnID
            transactionID: AETransactionID(0)   // kAnyTransactionID
        )
        if let directParameter {
            event.setParam(directParameter, forKeyword: keyDirectObject)
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
}
