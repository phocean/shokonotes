import SwiftUI

/// The search capsule, shared by the lists and by Find in Note.
/// A SwiftUI `TextField` so the capsule is a single fill (glass on iOS 26,
/// material on 17–18). Height and glyph calibre come from `IOSBottomBarMetrics`.
struct IOSSearchCapsule<Trailing: View>: View {
    @Binding var text: String
    var placeholder: String
    /// The host owns the focus state — the reader needs it to put the caret
    /// in the field when Find opens, and to close Find when the keyboard
    /// goes away on an empty query.
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}
    /// Inside the capsule, at its trailing edge: the dictation mic, and in
    /// the reader the "No results" note. Never a second background.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: IOSBottomBarMetrics.gap) {
            IOSBottomBarGlyph(systemImage: "magnifyingglass", tint: Color.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity)
            trailing
        }
        .padding(.horizontal, IOSBottomBarMetrics.gap)
        .frame(height: IOSBottomBarMetrics.controlHeight)
        .frame(maxWidth: .infinity)
        .iosControlGlass(in: Capsule())
    }
}

extension View {
    /// One fill layer on this control: Liquid Glass (iOS 26) or material.
    /// The shape is the control's, never a strip behind the bar.
    @ViewBuilder
    func iosControlGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}
