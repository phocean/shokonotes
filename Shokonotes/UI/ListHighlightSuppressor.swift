import SwiftUI
import AppKit

/// Stops SwiftUI's `List` from drawing its **own** selection highlight, so that
/// the row background the app hands the list is the only selection on screen.
///
/// `listRowBackground` was believed to *replace* the list's highlight. Measured
/// on the installed build, it does not: the focused note row filled to `#8385A0`,
/// which is exactly `0.8 × #828FBA` (`selectedContentBackgroundColor`, drawn by
/// the table) composited under `0.2 × #8A5A34` (the app's wash). The coloured
/// edges left and right of the band were that same system blue, uncovered, in the
/// few points the row background insets itself by. The sidebar showed the same
/// thing in grey: `#DCDCDC` is `unemphasizedSelectedContentBackgroundColor`.
///
/// An opaque wash alone cannot fix that — it would hide the blue in the middle of
/// the band and leave it showing in the 8 pt inset on each side. The highlight has
/// to stop being *drawn*, and the only place that decision lives is AppKit.
///
/// **What this does not do any more.** The first version set
/// `selectionHighlightStyle = .none` on the `NSTableView` itself, on the belief
/// that it was purely a drawing property. It is not: with it set, the library
/// lost its keyboard navigation. `NSTableView` treats that style as "behave as
/// if there were no selection at all", which reaches further than painting.
///
/// So it is now set on the **`NSTableRowView`** only, and the table's own
/// property is never written. A row view's `selectionHighlightStyle` governs
/// nothing but how that one row draws itself; it is not consulted for the
/// responder chain, for selection, or for key handling. Left / right between
/// panes, up / down inside a pane, Space to fold a folder — those keys are
/// therefore out of reach of this file.
///
/// **Why it has to be re-applied.** AppKit copies the *table's* highlight style
/// onto the row when that row becomes selected and when the view is reused.
/// Keyboard Up / Down is that path: after a few arrows the system blue returned
/// under the wash, most visibly in the inset on the right. The Probe is a 0×0
/// representable with no inputs, so SwiftUI often does not call `updateNSView`
/// again, and `viewDidMoveToWindow` does not re-fire on reuse. Watching the row
/// and the table's selection notifications is what puts `.none` back before the
/// blue is painted.
struct ListHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.suppress()
    }

    final class Probe: NSView {
        private var styleObservation: NSKeyValueObservation?
        private var selectedObservation: NSKeyValueObservation?
        private weak var observedRow: NSTableRowView?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            suppress()
        }

        /// Last moment before the row paints: AppKit has already copied the
        /// table's style onto the row during the key event. Put `.none` back
        /// so `drawSelection` is a no-op for this frame.
        override func viewWillDraw() {
            applyToObservedRow()
            super.viewWillDraw()
        }

        override func layout() {
            super.layout()
            applyToObservedRow()
        }

        deinit {
            styleObservation?.invalidate()
            selectedObservation?.invalidate()
        }

        func suppress() {
            var candidate: NSView? = superview
            while let current = candidate {
                if let rowView = current as? NSTableRowView {
                    watch(rowView)
                    apply(to: rowView)
                    if let table = enclosingTableView(from: rowView) {
                        TableHighlightStripper.install(on: table)
                    }
                    return
                }
                // Stop at the table: above it there is nothing this may touch.
                if current is NSTableView { return }
                candidate = current.superview
            }
        }

        private func applyToObservedRow() {
            if let observedRow {
                apply(to: observedRow)
            } else {
                suppress()
            }
        }

        private func apply(to rowView: NSTableRowView) {
            if rowView.selectionHighlightStyle != .none {
                rowView.selectionHighlightStyle = .none
            }
        }

        private func watch(_ rowView: NSTableRowView) {
            guard observedRow !== rowView else { return }
            styleObservation?.invalidate()
            selectedObservation?.invalidate()
            observedRow = rowView
            // These properties are not documented as KVO-compliant. When the
            // setter notifies, this is the same turn as AppKit's reset; when it
            // does not, the table stripper and `viewWillDraw` still run.
            styleObservation = rowView.observe(\.selectionHighlightStyle, options: [.new]) { [weak self] row, _ in
                self?.apply(to: row)
            }
            selectedObservation = rowView.observe(\.isSelected, options: [.new]) { [weak self] row, _ in
                self?.apply(to: row)
            }
        }

        private func enclosingTableView(from rowView: NSTableRowView) -> NSTableView? {
            var candidate: NSView? = rowView.superview
            while let current = candidate {
                if let table = current as? NSTableView { return table }
                candidate = current.superview
            }
            return nil
        }
    }
}

/// One observer per table. Keyboard selection is an `NSTableView` operation:
/// it posts `selectionDidChange` after copying the table's highlight style
/// onto the row views. Walking the *available* rows here covers reuse of a
/// row whose Probe was not asked to `updateNSView`.
private final class TableHighlightStripper {
    private static var associatedKey: UInt8 = 0

    static func install(on table: NSTableView) {
        // This stripper only runs from `NoteRowBackground`, so `table` is the
        // note list, not the sidebar outline.
        NoteListRowActions.register(table)
        if objc_getAssociatedObject(table, &associatedKey) != nil { return }
        let stripper = TableHighlightStripper(table: table)
        objc_setAssociatedObject(table, &associatedKey, stripper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private weak var table: NSTableView?
    private var observers: [NSObjectProtocol] = []

    private init(table: NSTableView) {
        self.table = table
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSTableView.selectionDidChangeNotification,
            NSTableView.selectionIsChangingNotification
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: table, queue: .main) { [weak self] _ in
                    self?.strip()
                    // AppKit sometimes writes the style after posting. The next
                    // turn still precedes the following key, so a stuck blue
                    // band cannot survive a second arrow.
                    DispatchQueue.main.async { [weak self] in
                        self?.strip()
                    }
                }
            )
        }
        strip()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func strip() {
        table?.enumerateAvailableRowViews { rowView, _ in
            if rowView.selectionHighlightStyle != .none {
                rowView.selectionHighlightStyle = .none
            }
        }
    }
}

extension View {
    /// Put this on the view handed to `listRowBackground`, in every list whose
    /// selection the app paints itself.
    func suppressingListHighlight() -> some View {
        background {
            ListHighlightSuppressor()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
