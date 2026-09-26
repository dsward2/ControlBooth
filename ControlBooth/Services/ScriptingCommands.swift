import AppKit

/// Handlers for the AppleEvent commands declared in ControlBooth.sdef.
/// Cocoa Scripting instantiates one per incoming event and calls
/// performDefaultImplementation() on the main thread, so hopping onto the
/// main actor with assumeIsolated is safe. Errors are reported back to the
/// sender through scriptErrorNumber/scriptErrorString.

@MainActor
private func scriptingServices(reportingTo command: NSScriptCommand) -> (store: PipelineStore, runner: PipelineRunner)? {
    guard let delegate = AppDelegate.shared,
          let store = delegate.store,
          let runner = delegate.runner else {
        command.scriptErrorNumber = NSInternalScriptError
        command.scriptErrorString = "ControlBooth is still launching; try again."
        return nil
    }
    return (store, runner)
}

@MainActor
private func airPlayService(reportingTo command: NSScriptCommand) -> AirPlayReceiverService? {
    guard let service = AppDelegate.shared?.airPlayReceiverService else {
        command.scriptErrorNumber = NSInternalScriptError
        command.scriptErrorString = "ControlBooth is still launching; try again."
        return nil
    }
    return service
}

@MainActor
private func requiredPipelineName(from command: NSScriptCommand) -> String? {
    guard let name = command.directParameter as? String, !name.isEmpty else {
        command.scriptErrorNumber = NSRequiredArgumentsMissingScriptError
        command.scriptErrorString = "A pipeline name is required."
        return nil
    }
    return name
}

@MainActor
private func pipeline(named name: String, in store: PipelineStore, reportingTo command: NSScriptCommand) -> Pipeline? {
    guard let match = store.pipelines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        command.scriptErrorNumber = NSArgumentsWrongScriptError
        command.scriptErrorString = "No pipeline named '\(name)'."
        return nil
    }
    return match
}

@objc(StartPipelineCommand)
nonisolated final class StartPipelineCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let name = requiredPipelineName(from: self),
                  let (store, runner) = scriptingServices(reportingTo: self),
                  let pipeline = pipeline(named: name, in: store, reportingTo: self) else {
                return nil
            }
            do {
                try runner.start(pipeline)
            } catch {
                scriptErrorNumber = NSInternalScriptError
                scriptErrorString = "\(error)"
            }
            return nil
        }
    }
}

@objc(StopPipelineCommand)
nonisolated final class StopPipelineCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let name = requiredPipelineName(from: self),
                  let (store, runner) = scriptingServices(reportingTo: self),
                  let pipeline = pipeline(named: name, in: store, reportingTo: self) else {
                return nil
            }
            runner.stop(pipeline)
            return nil
        }
    }
}

@objc(StopAllPipelinesCommand)
nonisolated final class StopAllPipelinesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (_, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            runner.stopAll()
            return nil
        }
    }
}

@objc(ListPipelinesCommand)
nonisolated final class ListPipelinesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (store, _) = scriptingServices(reportingTo: self) else {
                return nil
            }
            return store.pipelines.map(\.name)
        }
    }
}

@objc(RunningPipelinesCommand)
nonisolated final class RunningPipelinesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (store, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            return store.pipelines.filter { runner.isRunning($0) }.map(\.name)
        }
    }
}

@objc(AirPlayStatusCommand)
nonisolated final class AirPlayStatusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let service = airPlayService(reportingTo: self) else {
                return nil
            }
            return [service.isRunning, service.relayEnabled, service.isReceivingAudio]
        }
    }
}

@objc(StartAirPlayRelayCommand)
nonisolated final class StartAirPlayRelayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let service = airPlayService(reportingTo: self) else {
                return nil
            }
            service.remoteEnableRelay()
            return nil
        }
    }
}

@objc(StopAirPlayRelayCommand)
nonisolated final class StopAirPlayRelayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let service = airPlayService(reportingTo: self) else {
                return nil
            }
            service.remoteDisableRelay()
            return nil
        }
    }
}

@MainActor
private func reportFailure(_ error: Error, to command: NSScriptCommand) {
    command.scriptErrorNumber = NSInternalScriptError
    command.scriptErrorString = "\(error)"
}

@objc(DsdNeoStatusCommand)
nonisolated final class DsdNeoStatusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (store, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            return DsdNeoRemoteControl.statusJSON(store: store, runner: runner)
        }
    }
}

@objc(DsdNeoSetModeCommand)
nonisolated final class DsdNeoSetModeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (_, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            guard let name = directParameter as? String, let mode = DsdNeoFollowMode(rawValue: name) else {
                scriptErrorNumber = NSArgumentsWrongScriptError
                scriptErrorString = "The mode must be one of: "
                    + DsdNeoFollowMode.allCases.map(\.rawValue).joined(separator: ", ") + "."
                return nil
            }
            let talkgroup = (evaluatedArguments?["talkgroup"] as? NSNumber)?.intValue
            do {
                try DsdNeoRemoteControl.setMode(mode, holdTalkgroup: talkgroup, runner: runner)
            } catch {
                reportFailure(error, to: self)
            }
            return nil
        }
    }
}

@objc(DsdNeoSkipCommand)
nonisolated final class DsdNeoSkipCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (_, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            DsdNeoRemoteControl.skipCall(runner: runner)
            return nil
        }
    }
}

@objc(DsdNeoSetPolicyCommand)
nonisolated final class DsdNeoSetPolicyCommand: NSScriptCommand {
    static let policies: [String: DsdNeoTalkgroupOverrides.Policy] = [
        "lockout": .lockOut, "allow": .allow, "automatic": .automatic,
    ]

    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let (_, runner) = scriptingServices(reportingTo: self) else {
                return nil
            }
            guard let talkgroup = (directParameter as? NSNumber)?.intValue,
                  let name = evaluatedArguments?["policy"] as? String,
                  let policy = Self.policies[name] else {
                scriptErrorNumber = NSArgumentsWrongScriptError
                scriptErrorString = "A talkgroup number and a policy (lockout, allow or automatic) are required."
                return nil
            }
            do {
                try DsdNeoRemoteControl.setPolicy(policy, for: talkgroup, runner: runner)
            } catch {
                reportFailure(error, to: self)
            }
            return nil
        }
    }
}
