import SwiftUI
import AppKit

/// Gives a pane the keyboard when it is clicked.
///
/// Its clients are the **note list and the preview**, and only those. The folder
/// column is an `NSOutlineView` (`SidebarSourceList`): clicking it already makes
/// it the first responder, and putting this catcher behind it would write
/// SwiftUI focus state on every click in the column — the first step of the
/// focus loop that contract is written to prevent.
///
/// SwiftUI's `List` updates its selection binding on a click but never touches
/// `@FocusState`, so clicking a row moved the selection and nothing else: the
/// arrow keys went on driving the other pane, this one stayed on the unfocused
/// grey, and the mouse and the keyboard were writing two different states.
///
/// `simultaneousGesture(TapGesture())` does not work here — measured. The list
/// consumes the click itself, the gesture never recognises, and the focus state
/// does not move.
///
/// So the click is observed at the AppKit level, where nothing can swallow it.
/// The monitor sees every left mouse down in the window and the view checks
/// whether the point falls inside **its own bounds** — installed as a pane's
/// background, that makes each catcher self-locating: no frame bookkeeping, no
/// deciding from coordinates which pane was hit. The event is returned
/// unchanged, so selection, dragging, double-click and the context menu behave
/// exactly as before.
///
/// It reports the *click*, deliberately not the selection. Selection also
/// changes with no click behind it — a search, an external delete, a quick
/// capture — and taking the keyboard on those would be the same bug pointing the
/// other way.
///
/// What it calls must write the same `@FocusState` the arrow keys write, so that
/// there is one focus state however it was reached. Two near-identical paths is
/// what produced every focus defect before this one.
struct PaneClickFocus: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView { Catcher(onClick: onClick) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Catcher)?.onClick = onClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? Catcher)?.stop()
    }

    final class Catcher: NSView {
        var onClick: () -> Void
        private var monitor: Any?

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not in a nib") }

        /// Never in the way: the monitor does the listening, so this view has no
        /// reason to take a click of its own.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onClick()
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    /// Put this on a pane, not on its rows.
    func focusingPaneOnClick(_ onClick: @escaping () -> Void) -> some View {
        background { PaneClickFocus(onClick: onClick) }
    }
}
