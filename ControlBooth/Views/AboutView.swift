import SwiftUI

struct AboutView: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        if build == version {
            return version
        }
        return "\(version) (Build \(build))"
    }

    /// Set by macOS only when the process is running under the App Sandbox
    /// (see `com.apple.security.app-sandbox`). ControlBooth is unsandboxed —
    /// it needs unrestricted access to run arbitrary pipeline tools — so this
    /// should normally read "Disabled".
    private var appSandboxStatus: String {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "Enabled" : "Disabled"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 28)

            Text("ControlBooth")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 12)

            Text("Version \(versionString)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Text("Pipeline control and scheduling for AntennaHead.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Link("AntennaHead on GitHub",
                 destination: URL(string: "https://github.com/dsward2/AntennaHead")!)
                .font(.body)
                .padding(.top, 8)

            Divider()
                .padding(.horizontal, 24)
                .padding(.top, 20)

            Text("© 2026 dsward2. All rights reserved.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Text("App Sandbox: \(appSandboxStatus)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, 12)
        }
        .frame(width: 340)
    }
}
