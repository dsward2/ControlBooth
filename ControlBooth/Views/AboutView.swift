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
                .padding(.vertical, 12)
        }
        .frame(width: 340)
    }
}
