import AppKit
import SwiftTerm
import SwiftUI

/// dsd-neo's live terminal UI, drawn by SwiftTerm from the scanner's
/// pseudo-terminal. Keystrokes go back to dsd-neo, and the view's size
/// becomes the pty size, so dsd-neo lays its screens out to fit.
struct DsdNeoTerminalView: NSViewRepresentable {
    let scanner: DsdNeoScanner

    func makeCoordinator() -> Coordinator { Coordinator(scanner: scanner) }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero,
                                    font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        terminal.terminalDelegate = context.coordinator
        terminal.optionAsMetaKey = false
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let scanner: DsdNeoScanner
        private weak var terminal: TerminalView?

        init(scanner: DsdNeoScanner) {
            self.scanner = scanner
        }

        /// Replays recent output so the screen isn't blank until dsd-neo next
        /// redraws, then streams live output.
        func attach(_ terminal: TerminalView) {
            self.terminal = terminal
            let backlog = scanner.terminalBacklog
            if !backlog.isEmpty { terminal.feed(byteArray: ArraySlice(backlog)) }
            scanner.onTerminalOutput = { [weak self] data in
                self?.terminal?.feed(byteArray: ArraySlice(data))
            }
        }

        func detach() {
            scanner.onTerminalOutput = nil
        }

        // MARK: TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated { scanner.sendToTerminal(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            MainActor.assumeIsolated {
                scanner.resizeTerminal(columns: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
