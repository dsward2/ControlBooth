import Foundation

/// Decides when a running dsd-neo has wedged and must be restarted.
///
/// Seen in practice (v2.8.1): a corrupted P25 "Channel Identifier Update"
/// heard on a voice channel poisons dsd-neo's band plan, after which it
/// computes a nonsense control-channel frequency (e.g. 3508 MHz), retunes
/// there and hunts forever. A fresh start re-learns the band plan from the
/// real control channel within seconds.
nonisolated struct DsdNeoWatchdog {
    enum Reason: Equatable, CustomStringConvertible {
        case invalidRetune(hertz: Int)
        case controlChannelLost(times: Int)

        var description: String {
            switch self {
            case .invalidRetune(let hz):
                return "retuned to \(hz) Hz, outside what an RTL-SDR can receive"
            case .controlChannelLost(let times):
                return "lost the control channel \(times) times in a row"
            }
        }
    }

    /// RTL-SDR (R820T/R828D) tuning range.
    static let tunableHertz = 24_000_000...1_766_000_000
    /// Consecutive control-channel losses, with no P25 sync between them.
    static let maxConsecutiveLosses = 6

    private var consecutiveLosses = 0

    /// Feeds one parsed log event; returns why dsd-neo should be restarted,
    /// or nil while it looks healthy.
    mutating func observe(_ event: DsdNeoLogEvent) -> Reason? {
        switch event {
        case .retune(let hz) where !Self.tunableHertz.contains(hz):
            return .invalidRetune(hertz: hz)
        case .controlChannelLost:
            consecutiveLosses += 1
            if consecutiveLosses >= Self.maxConsecutiveLosses {
                consecutiveLosses = 0
                return .controlChannelLost(times: Self.maxConsecutiveLosses)
            }
        case .p25Sync, .tunedToGrant:
            consecutiveLosses = 0
        default:
            break
        }
        return nil
    }
}

/// Limits automatic restarts so a scanner that can never work (antenna
/// unplugged, wrong frequency) gives up instead of restarting forever.
nonisolated struct DsdNeoRestartBudget {
    static let maxRestarts = 5
    static let window: TimeInterval = 120

    private var restarts: [Date] = []

    /// Records a restart at `now`; false when the budget is spent.
    mutating func allowRestart(at now: Date) -> Bool {
        restarts.removeAll { now.timeIntervalSince($0) > Self.window }
        guard restarts.count < Self.maxRestarts else { return false }
        restarts.append(now)
        return true
    }
}
