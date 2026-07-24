import SwiftUI

@main
struct ControlBoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PipelineStore()
    @State private var runner = PipelineRunner()
    @State private var eventStore = ScheduledEventStore()
    @State private var scheduler = Scheduler()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(runner)
                .environment(eventStore)
                .environment(scheduler)
                .onAppear {
                    appDelegate.runner = runner
                    appDelegate.store = store
                    scheduler.reschedule(events: eventStore.events, pipelineStore: store, runner: runner)
                }
                .onChange(of: eventStore.events) {
                    scheduler.reschedule(events: eventStore.events, pipelineStore: store, runner: runner)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                OpenAboutWindowButton()
            }
        }

        Window("About ControlBooth", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

private struct OpenAboutWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About ControlBooth") {
            openWindow(id: "about")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // On macOS, NSApp.delegate is SwiftUI's internal delegate, not this
    // adaptor instance — scripting commands reach us through `shared`.
    private(set) static weak var shared: AppDelegate?

    var runner: PipelineRunner?
    var store: PipelineStore?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Graceful teardown on normal quit; on a crash the helpers'
        // --exit-with-parent watchdogs collapse the pipelines instead.
        runner?.stopAll()
    }
}
