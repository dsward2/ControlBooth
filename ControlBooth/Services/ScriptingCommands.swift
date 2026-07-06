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
