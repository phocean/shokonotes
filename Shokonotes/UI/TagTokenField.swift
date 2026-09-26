import AppKit
import SwiftUI

/// The typing half of the tag editor: an `NSTokenField`, because nothing in
/// SwiftUI is one.
///
/// Several tags in one pass — a comma or Return makes a token, Backspace eats
/// the last one — and each token is **written the moment it is made**. There is
/// no OK button anywhere in this editor (decided 2026-09-13), so "committed"
/// means "on disk", and the field is not a draft waiting for a verb.
///
/// # The completion seam
///
/// `completions` is handed the substring being typed and returns the names to
/// offer, best first; an empty array offers nothing. The delegate method is
/// `tokenField(_:completionsForSubstring:indexOfToken:indexOfSelectedItem:)`.
///
/// # Why `updateNSView` does not reseed
///
/// Every token written here calls `applyTag`, which reloads the library and
/// republishes. If `updateNSView` copied the model back into the field, that
/// republish would land mid-word and rewrite the text under the caret. So the
/// field is seeded **once**, in `makeNSView`, and the coordinator owns it for
/// the popover's short life. The checkable list below is the live view of the
/// truth; the field is the input.
struct TagTokenField: NSViewRepresentable {
    /// The tags carried by **every** note in the selection, shown as tokens.
    /// Tags carried by only some of them are not tokens — they are the dash in
    /// the list below, which is the surface that can say "some".
    let initialTokens: [String]
    let placeholder: String
    /// Ranked completions for the substring being typed. Empty offers nothing.
    let completions: (String) -> [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    /// The half-typed word, reported on every keystroke, so the popover can ask
    /// the engine whether it is about to become a duplicate. Empty when there is
    /// nothing uncommitted in the field.
    let onTyping: (String) -> Void
    /// Tab leaves the field for the list below, so the popover is crossable
    /// without a pointer.
    let onTab: () -> Void
    let onEscape: () -> Void
    /// The one way the view above reaches back into this field — see `Handle`.
    let handle: Handle

    /// The hygiene offer's accept button lives in `TagPopover`, but accepting it
    /// has to happen *inside* this field: the half-typed word is the field's,
    /// not the model's. So the coordinator publishes one closure here and the
    /// popover calls it. Deliberately one verb and no state: this is not a
    /// second controller for the field.
    final class Handle {
        fileprivate var acceptOffer: ((String) -> Void)?

        /// Put `tag` in the field in place of what is being typed, and write it.
        /// Nothing happens if the field has gone away.
        func accept(_ tag: String) { acceptOffer?(tag) }
    }

    /// What a field-editor command means to this editor.
    ///
    /// Pure, and separated from the delegate so the whole keyboard contract of
    /// the field can be read and tested without a window.
    enum FieldCommand: Hashable {
        /// Tab: leave the field for the checkable list below.
        case leaveField
        /// Escape: close the editor. One press, always — see below.
        case closeEditor
        /// Not ours. Hand it back to AppKit.
        case passThrough
    }

    /// # Escape is one step, and why it stopped being two
    ///
    /// It was briefly two: the first Escape was handed back to AppKit to close
    /// its completion list, the second closed the popover. That rested on a flag
    /// set from `tokenField(_:completionsForSubstring:…)` — which AppKit calls to
    /// **populate** a list, before and independently of showing one (`NSTokenField`
    /// has a `completionDelay`, and a list that is offered may never appear). So
    /// the flag said "a list is open" when nothing was on screen, and an Escape
    /// typed before the menu dropped down was spent clearing it: the press did
    /// nothing visible and the popover stayed open. A key that sometimes does
    /// nothing is exactly the doubt this editor exists to remove.
    ///
    /// AppKit offers no way to ask whether the list is showing. What the SDK
    /// headers do say is that a live completion session reports its own end
    /// through `NSTextView.insertCompletion(_:forPartialWordRange:movement:isFinal:)`
    /// — "canceling completion" arrives there as `NSTextMovement.cancel`, on the
    /// field editor, which this popover does not own and cannot override without
    /// vending its own. The reading that follows is that an Escape which reaches
    /// *this* delegate is an Escape the completion session did not take, and the
    /// two-step could only ever fire in the case where it swallowed the key.
    ///
    /// So: Escape closes the editor, every time. If AppKit's list were somehow up,
    /// closing the popover tears the field down and the list goes with it — no
    /// orphan menu is left behind.
    static func command(for selector: Selector) -> FieldCommand {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): return .leaveField
        case #selector(NSResponder.cancelOperation(_:)): return .closeEditor
        default: return .passThrough
        }
    }

    /// The word being typed, which sits in the field's value **beside** the
    /// tokens. Pure, so the rule that separates a half-typed word from a real
    /// token can be tested without a field editor.
    static func partial(in value: [String], committed: [String]) -> String {
        value.last(where: { !committed.contains($0) })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        // The popover draws the box, exactly as the folder-symbol picker's
        // search field does: one device, one geometry.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.placeholderString = placeholder
        field.objectValue = initialTokens
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.committed = initialTokens

        // The accept door for the hygiene offer. `field` is held weakly: the
        // popover outlives nothing here, but a closure that owns its own view
        // is a retain cycle waiting for the one case where it does.
        handle.acceptOffer = { [weak field, weak coordinator = context.coordinator] tag in
            guard let field, let coordinator else { return }
            coordinator.accept(tag, in: field)
        }

        // The field opens with the keyboard, so typing is the first thing that
        // works. This never touches `SidebarSourceList`'s focus token: the
        // popover has its own window, and closing it hands the responder back
        // to whatever held it.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Deliberately nothing else. See "Why `updateNSView` does not reseed".
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagTokenField
        /// The tokens this field has already written. Compared against the
        /// field's own value to notice a Backspace, which AppKit reports
        /// through no delegate method of its own.
        var committed: [String] = []

        init(_ parent: TagTokenField) {
            self.parent = parent
        }

        /// Accept a hygiene offer: replace the half-typed word with the existing
        /// tag. The typed spelling is not rewritten in place.
        func accept(_ tag: String, in field: NSTokenField) {
            if !committed.contains(tag) {
                committed.append(tag)
                field.objectValue = committed
                parent.onAdd(tag)
            } else {
                // Already a token — just clear the duplicate being typed.
                field.objectValue = committed
            }
            parent.onTyping("")
            field.window?.makeFirstResponder(field)
        }

        func tokenField(
            _ tokenField: NSTokenField,
            shouldAdd tokens: [Any],
            at index: Int
        ) -> [Any] {
            let accepted = tokens.compactMap { token -> String? in
                guard let text = token as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !committed.contains(trimmed) else { return nil }
                return trimmed
            }
            for tag in accepted {
                committed.append(tag)
                parent.onAdd(tag)
            }
            // A token was made: there is no half-typed word left to warn about.
            if !accepted.isEmpty {
                parent.onTyping("")
            }
            return accepted
        }

        /// The removal half. Fires on every keystroke, so it must not mistake a
        /// half-typed word for a token: the uncommitted text sits in the field's
        /// value **beside** the tokens, never in place of one, so a name that is
        /// still present is still a token.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField,
                  let current = field.objectValue as? [String] else { return }
            let removed = committed.filter { !current.contains($0) }
            if !removed.isEmpty {
                committed.removeAll { removed.contains($0) }
                for tag in removed { parent.onRemove(tag) }
            }
            parent.onTyping(TagTokenField.partial(in: current, committed: committed))
        }

        /// The seam. Nothing is invented here.
        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            parent.completions(substring)
        }

        /// Tab and Escape, taken from the field editor so the popover answers
        /// the keyboard the same way whichever half holds it. The rule itself is
        /// `TagTokenField.command(for:)` — including why Escape is one press.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch TagTokenField.command(for: selector) {
            case .leaveField:
                parent.onTab()
                return true
            case .closeEditor:
                parent.onEscape()
                return true
            case .passThrough:
                return false
            }
        }
    }
}
