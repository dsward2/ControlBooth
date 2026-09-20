import AppKit
import SwiftUI

extension View {
    /// `.help(_:)` plus an AppKit-backed tooltip.
    ///
    /// SwiftUI's `.help` sets the accessibility help and a tooltip on the
    /// hosting view, but for borderless buttons inside the grouped `Form`
    /// (the Stages section of the pipeline editor) the tooltip never appears
    /// on hover. An `NSView` with its own `toolTip`, placed behind the
    /// control, registers a tooltip rect with the window directly and does.
    func helpTip(_ text: String) -> some View {
        help(text).background(HelpTipAnchor(text: text))
    }
}

private struct HelpTipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
    }

    /// Never takes clicks, so it can't interfere with the control it sits behind.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
