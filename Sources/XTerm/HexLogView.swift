import AppKit
import SwiftUI

/// A no-wrap, two-axis HEX log view with deterministic bottom-left following.
///
/// NSTextStorage is updated incrementally so high-rate serial traffic does not
/// repeatedly allocate all previously rendered HEX strings.
struct HexLogView: NSViewRepresentable {
    let entries: [LogEntry]
    let timestampEnabled: Bool
    let followTail: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let needsRebuild =
            coordinator.timestampEnabled != timestampEnabled ||
            entries.count < coordinator.renderedCount ||
            (coordinator.renderedCount > 0 &&
             (entries.first?.id != coordinator.firstID ||
              entries[coordinator.renderedCount - 1].id != coordinator.lastID))

        if needsRebuild {
            coordinator.rebuild(entries: entries, timestampEnabled: timestampEnabled)
        } else if entries.count > coordinator.renderedCount {
            coordinator.append(
                entries: entries[coordinator.renderedCount...],
                timestampEnabled: timestampEnabled
            )
        }

        coordinator.timestampEnabled = timestampEnabled
        if followTail && (needsRebuild || entries.count != coordinator.lastFollowedCount) {
            coordinator.scrollToBottomLeft()
            coordinator.lastFollowedCount = entries.count
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var renderedCount = 0
        var firstID: UUID?
        var lastID: UUID?
        var timestampEnabled: Bool?
        var lastFollowedCount = -1

        func rebuild(entries: [LogEntry], timestampEnabled: Bool) {
            guard let storage = textView?.textStorage else { return }
            storage.setAttributedString(NSAttributedString())
            renderedCount = 0
            firstID = nil
            lastID = nil
            append(entries: entries[...], timestampEnabled: timestampEnabled)
        }

        func append(entries: ArraySlice<LogEntry>, timestampEnabled: Bool) {
            guard !entries.isEmpty, let storage = textView?.textStorage else {
                renderedCount = 0
                firstID = nil
                lastID = nil
                return
            }
            let addition = NSMutableAttributedString()
            for entry in entries {
                addition.append(Self.render(entry, timestampEnabled: timestampEnabled))
            }
            storage.append(addition)
            renderedCount += entries.count
            firstID = firstID ?? entries.first?.id
            lastID = entries.last?.id
            resizeDocumentToContent()
        }

        func scrollToBottomLeft() {
            guard let scrollView, let textView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            resizeDocumentToContent()
            let maximumY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func resizeDocumentToContent() {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            textView.frame.size = NSSize(
                width: max(scrollView.contentView.bounds.width, ceil(used.width + inset.width * 2)),
                height: max(scrollView.contentView.bounds.height, ceil(used.height + inset.height * 2))
            )
        }

        private static func render(_ entry: LogEntry, timestampEnabled: Bool) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

            if timestampEnabled {
                result.append(NSAttributedString(
                    string: "\(timestampFormatter.string(from: entry.timestamp))  ",
                    attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }

            let directionColor: NSColor
            switch entry.direction {
            case .received: directionColor = .systemBlue
            case .sent: directionColor = .systemGreen
            case .system: directionColor = .systemOrange
            }
            result.append(NSAttributedString(
                string: "\(entry.direction.rawValue.padding(toLength: 3, withPad: " ", startingAt: 0)) ",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                             .foregroundColor: directionColor]
            ))

            let content = entry.message ?? DataCodec.display(entry.data, mode: .hex)
            result.append(NSAttributedString(string: content, attributes: base))
            result.append(NSAttributedString(string: "\n", attributes: base))
            return result
        }

        private static let timestampFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }
}
