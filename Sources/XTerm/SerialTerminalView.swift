import AppKit
import SwiftUI
import SwiftTerm

/// AppKit-backed VT100/xterm renderer for the serial byte stream.
///
/// Serial reads are deliberately fed as one continuous stream. SwiftTerm keeps
/// parser and UTF-8 state across chunks, so an escape sequence or Unicode scalar
/// split between two `read()` calls is still decoded correctly.
struct SerialTerminalView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.caretViewTracksFocus = true
        terminal.scrollerStyle = .overlay
        terminal.changeScrollback(1_000)
        terminal.terminal.options.kittyImageCacheLimitBytes = 8 * 1024 * 1024
        terminal.terminal.options.enableSixelReported = false
        context.coordinator.terminalView = terminal

        model.setTerminalHandler { [weak terminal] data in
            guard let terminal else { return }
            if let data {
                terminal.feed(byteArray: Array(data)[...])
            } else {
                // RIS resets parser state, screen contents, cursor and attributes.
                terminal.feed(byteArray: [0x1B, 0x63][...])
            }
        }
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.model.setTerminalHandler(nil)
        nsView.terminalDelegate = nil
        coordinator.terminalView = nil
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var model: AppModel
        weak var terminalView: TerminalView?

        init(model: AppModel) {
            self.model = model
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let packet = Data(data)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try model.send(packet)
                } catch {
                    model.lastError = error.localizedDescription
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        func clipboardRead(source: TerminalView) -> Data? {
            // Deliberately deny remote clipboard reads.
            nil
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
