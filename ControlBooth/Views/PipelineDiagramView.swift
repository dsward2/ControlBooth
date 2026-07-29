import SwiftUI

/// Left-to-right flow diagram of a running pipeline's stages — a native
/// SwiftUI counterpart to AntennaHead's inline-SVG pipeline diagram (see
/// AntennaHead's `StatusWebView`), reusing the same visual language: a
/// rounded node per stage with a status dot, connected by arrows, with the
/// full path + arguments available on hover.
struct PipelineDiagramView: View {
    struct DiagramStage: Identifiable {
        let id = UUID()
        var name: String
        var detail: String
        var path: String
        var args: [String]
        var running: Bool
    }

    let stages: [DiagramStage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    if index > 0 {
                        connector
                    }
                    StageNodeView(stage: stage)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var connector: some View {
        VStack(spacing: 2) {
            Text("PIPE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }
}

private struct StageNodeView: View {
    let stage: PipelineDiagramView.DiagramStage
    @State private var showingDetail = false

    private var dotColor: Color {
        stage.running ? Color(red: 0.204, green: 0.780, blue: 0.349) // matches AntennaHead --on
                      : Color(red: 1.0, green: 0.271, blue: 0.227)   // matches AntennaHead --off
    }

    private var borderColor: Color {
        stage.running ? Color.accentColor : Color(nsColor: .separatorColor)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(stage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .frame(width: 168, height: 70, alignment: .topLeading)

            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: 1.5))
        .onHover { hovering in showingDetail = hovering }
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.name)
                    .font(.headline)
                Text(stage.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if !stage.args.isEmpty {
                    Text(stage.args.joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }
}
