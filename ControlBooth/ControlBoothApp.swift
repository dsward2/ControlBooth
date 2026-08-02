import AppKit
import SwiftUI
import SharedLogging

@main
struct ControlBoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PipelineStore()
    @State private var runner = PipelineRunner()
    @State private var eventStore = ScheduledEventStore()
    @State private var scheduler = Scheduler()
    @State private var airPlaySettingsStore = AirPlaySettingsStore()
    @State private var airPlayReceiverService = AirPlayReceiverService()

    init() {
        LogStore.shared.configure(appName: "ControlBooth")
    }

    var body: some Scene {
        Window("ControlBooth", id: "main") {
            ContentView()
                .environment(store)
                .environment(runner)
                .environment(eventStore)
                .environment(scheduler)
                .environment(airPlaySettingsStore)
                .environment(airPlayReceiverService)
                .background(CloseButtonHider())
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
        .commands {
            CommandGroup(replacing: .appInfo) {
                OpenAboutWindowButton()
            }
            CommandMenu("Window") {
                OpenLogsWindowButton()
            }
        }

        Window("About ControlBooth", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogViewerView()
        }
        .defaultSize(width: 800, height: 500)
    }
}

private struct CloseButtonHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.standardWindowButton(.closeButton)?.isHidden = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct OpenAboutWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About ControlBooth") {
            openWindow(id: "about")
        }
    }
}

private struct OpenLogsWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Logs") {
            openWindow(id: "logs")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
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
