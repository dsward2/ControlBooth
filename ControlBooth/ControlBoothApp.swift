import SwiftUI

@main
struct ControlBoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PipelineStore()
    @State private var runner = PipelineRunner()
    @State private var eventStore = ScheduledEventStore()
    @State private var scheduler = Scheduler()
    @State private var airPlaySettingsStore = AirPlaySettingsStore()
    @State private var airPlayReceiverService = AirPlayReceiverService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(runner)
                .environment(eventStore)
                .environment(scheduler)
                .environment(airPlaySettingsStore)
                .environment(airPlayReceiverService)
                .onAppear {
                    appDelegate.runner = runner
                    appDelegate.store = store
                    appDelegate.airPlayReceiverService = airPlayReceiverService
                    scheduler.reschedule(events: eventStore.events, pipelineStore: store, runner: runner)
                    airPlayReceiverService.applySettings(airPlaySettingsStore.settings)
                }
                .onChange(of: eventStore.events) {
                    scheduler.reschedule(events: eventStore.events, pipelineStore: store, runner: runner)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // On macOS, NSApp.delegate is SwiftUI's internal delegate, not this
    // adaptor instance — scripting commands reach us through `shared`.
    private(set) static weak var shared: AppDelegate?

    var runner: PipelineRunner?
    var store: PipelineStore?
    var airPlayReceiverService: AirPlayReceiverService?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Graceful teardown on normal quit; on a crash the helpers'
        // --exit-with-parent watchdogs collapse the pipelines instead.
        runner?.stopAll()
        airPlayReceiverService?.stopAll()
    }
}
