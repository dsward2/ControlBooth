import SwiftUI

@main
struct ControlBoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PipelineStore()
    @State private var runner = PipelineRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(runner)
                .onAppear {
                    appDelegate.runner = runner
                    appDelegate.store = store
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
