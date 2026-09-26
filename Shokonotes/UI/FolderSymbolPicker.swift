import AppKit
import SwiftUI

/// The closed catalogue a folder may choose its glyph from.
///
/// A few hundred names, not the SF Symbols catalogue: a folder is filed, not
/// decorated, and a wall of ten thousand glyphs is a worse answer than a short
/// one you can read. The names live in the source — a resource file would mean
/// a second place to keep valid, and the list is not user data.
///
/// Availability is checked once at load: a name this macOS does not know is
/// dropped rather than drawn, so a symbol added in a later release can sit in
/// the list without putting an empty cell in the grid on macOS 14.
enum FolderSymbolCatalogue {
    struct Group: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let names: [String]
    }

    /// Every name the picker may show, grouped. Filtered to what the running
    /// system can actually draw.
    /// Deduplicated as well as filtered: a name is a SwiftUI identity in the
    /// grid, and the same glyph listed under two groups would collide.
    static let groups: [Group] = {
        var seen = Set<String>()
        return rawGroups.compactMap { group in
            let available = group.names.filter { exists($0) && seen.insert($0).inserted }
            guard !available.isEmpty else { return nil }
            return Group(id: group.id, title: group.title, names: available)
        }
    }()

    /// True when the running system can draw this symbol. Callers that display a
    /// stored name use `resolved(_:)` instead.
    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The answer `resolved(_:)` already gave for a stored name.
    ///
    /// Seeded with the catalogue, which has paid for its own availability check
    /// once at load; every other name — one carried over from a newer build, or
    /// a typo — costs a single `NSImage` and is then remembered. Availability
    /// cannot change while the app runs, so the answer never goes stale.
    ///
    /// Read and written from the sidebar row body and the drag preview, both on
    /// the main actor. Nothing off it calls `resolved(_:)`.
    private static var resolutions: [String: String] = Dictionary(
        groups.flatMap(\.names).map { ($0, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The name to draw for a folder: its own symbol when the system knows it,
    /// the default glyph otherwise. A symbol stored by a newer build, or one
    /// removed by Apple, degrades to a folder instead of an empty row.
    ///
    /// Memoized per name. It is called once per visible sidebar row on every
    /// redraw — a selection change, a keystroke in search, a resize — and the
    /// availability test allocates an `NSImage` it then throws away.
    static func resolved(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return defaultSymbol }
        if let known = resolutions[name] { return known }
        let answer = exists(name) ? name : defaultSymbol
        resolutions[name] = answer
        return answer
    }

    static let defaultSymbol = "folder"

    static func groups(matching query: String) -> [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.names.filter { $0.lowercased().contains(needle) }
            guard !hits.isEmpty else { return nil }
            return Group(id: group.id, title: group.title, names: hits)
        }
    }

    private static let rawGroups: [Group] = [
        Group(id: "folders", title: "Folders", names: [
            "folder", "folder.fill", "folder.badge.plus", "folder.badge.gearshape",
            "folder.badge.person.crop", "externaldrive", "externaldrive.fill",
            "internaldrive", "archivebox", "archivebox.fill", "tray", "tray.full",
            "tray.2", "shippingbox", "shippingbox.fill", "cube", "cube.box",
            "square.stack", "square.stack.3d.up", "rectangle.stack", "books.vertical"
        ]),
        Group(id: "documents", title: "Documents", names: [
            "doc", "doc.fill", "doc.text", "doc.text.fill", "doc.richtext",
            "doc.plaintext", "doc.on.doc", "doc.append", "doc.badge.plus",
            "note", "note.text", "text.book.closed", "book", "book.fill",
            "book.closed", "bookmark", "bookmark.fill", "newspaper", "magazine",
            "list.bullet", "list.bullet.clipboard", "list.number", "checklist",
            "text.quote", "text.alignleft", "signature", "pencil", "pencil.line",
            "highlighter", "paperclip", "link", "printer", "scanner"
        ]),
        Group(id: "work", title: "Work", names: [
            "briefcase", "briefcase.fill", "case", "suitcase", "building",
            "building.2", "building.columns", "house", "house.fill",
            "desktopcomputer", "laptopcomputer", "keyboard", "display",
            "server.rack", "network", "chart.bar", "chart.pie", "chart.xyaxis.line",
            "chart.line.uptrend.xyaxis", "dollarsign.circle", "eurosign.circle",
            "creditcard", "banknote", "cart", "bag", "tag", "tag.fill",
            "calendar", "calendar.badge.clock", "clock", "alarm", "timer",
            "stopwatch", "hourglass", "graduationcap", "studentdesk", "ruler",
            "paintbrush", "paintpalette", "hammer", "wrench", "wrench.and.screwdriver",
            "screwdriver", "gearshape", "gearshape.2", "slider.horizontal.3"
        ]),
        Group(id: "communication", title: "Communication", names: [
            "envelope", "envelope.fill", "envelope.open", "paperplane",
            "paperplane.fill", "bubble.left", "bubble.left.and.bubble.right",
            "text.bubble", "quote.bubble", "phone", "phone.fill", "video",
            "megaphone", "bell", "bell.fill", "bell.badge", "at", "person",
            "person.fill", "person.2", "person.3", "person.crop.circle",
            "figure.stand", "figure.wave", "hand.wave", "hands.clap",
            "globe", "globe.europe.africa", "globe.americas", "network.badge.shield.half.filled"
        ]),
        Group(id: "media", title: "Media", names: [
            "photo", "photo.on.rectangle", "camera", "camera.fill", "film",
            "play.rectangle", "tv", "music.note", "music.note.list", "guitars",
            "pianokeys", "headphones", "mic", "mic.fill", "waveform",
            "speaker.wave.2", "radio", "dot.radiowaves.left.and.right",
            "rectangle.3.group", "paintbrush.pointed", "theatermasks", "ticket"
        ]),
        Group(id: "nature", title: "Nature", names: [
            "leaf", "leaf.fill", "tree", "carrot", "fork.knife", "cup.and.saucer",
            "mug", "wineglass", "birthday.cake", "flame", "drop", "drop.fill",
            "snowflake", "sun.max", "sun.horizon", "moon", "moon.stars",
            "cloud", "cloud.rain", "cloud.bolt", "wind", "tornado", "sparkles",
            "star", "star.fill", "sparkle", "atom", "hare", "tortoise", "ant",
            "ladybug", "fish", "bird", "pawprint", "pawprint.fill", "mountain.2",
            "water.waves", "globe.desk"
        ]),
        Group(id: "travel", title: "Travel", names: [
            "airplane", "airplane.departure", "car", "car.fill", "bus", "tram",
            "bicycle", "scooter", "sailboat", "ferry", "fuelpump", "map",
            "mappin", "mappin.and.ellipse", "location", "location.fill",
            "signpost.right", "road.lanes", "suitcase.rolling", "beach.umbrella",
            "tent", "binoculars", "backpack", "camera.macro"
        ]),
        Group(id: "health", title: "Health", names: [
            "heart", "heart.fill", "heart.text.square", "bandage", "cross.case",
            "pills", "stethoscope", "brain.head.profile", "eye", "ear",
            "figure.walk", "figure.run", "figure.yoga", "figure.pool.swim",
            "figure.hiking", "dumbbell", "sportscourt", "bed.double", "shower",
            "bathtub", "fork.knife.circle"
        ]),
        Group(id: "objects", title: "Objects", names: [
            "lightbulb", "lightbulb.fill", "key", "lock", "lock.fill",
            "lock.open", "shield", "shield.lefthalf.filled", "flag", "flag.fill",
            "pin", "pin.fill", "gift", "crown", "trophy", "medal", "puzzlepiece",
            "gamecontroller", "dice", "scissors", "trash", "bolt", "bolt.fill",
            "battery.100", "powerplug", "antenna.radiowaves.left.and.right",
            "wifi", "icloud", "arrow.up.doc", "externaldrive.badge.icloud",
            "magnifyingglass", "eyeglasses", "binoculars.fill", "flashlight.on.fill",
            "umbrella", "basket", "washer", "sofa", "chair", "lamp.desk",
            "cabinet", "toilet", "spigot", "wallet.pass"
        ]),
        Group(id: "shapes", title: "Shapes", names: [
            "circle", "circle.fill", "square", "square.fill", "triangle",
            "triangle.fill", "diamond", "diamond.fill", "hexagon", "hexagon.fill",
            "seal", "seal.fill", "capsule", "rhombus", "app", "square.grid.2x2",
            "circle.grid.3x3", "number", "asterisk", "exclamationmark.circle",
            "questionmark.circle", "checkmark.circle", "xmark.circle",
            "plus.circle", "minus.circle", "arrow.right.circle", "arrow.triangle.branch",
            "arrow.triangle.2.circlepath", "infinity", "command", "option"
        ])
    ]
}

/// Bear's tag editor, taken as far as the product allows: a grid of glyphs, a
/// search field at the bottom, the current one marked — and none of its colour.
/// The symbol stays system-tinted; the chocolate wash of the note list remains
/// the only identity accent in the app.
struct FolderSymbolPicker: View {
    let title: String
    let current: String?
    /// Applied immediately: a click picks and dismisses. Nil restores the
    /// default glyph. There is no OK and no Cancel — undoing a mistake is one
    /// more click, which is cheaper than confirming every correct choice.
    let choose: (String?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Six fixed columns, as in the reference. Adaptive columns would reflow the
    /// grid as the search narrows it, which makes the glyphs jump under the
    /// pointer between keystrokes.
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 12), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Button("Default") { choose(nil) }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(FolderSymbolCatalogue.groups(matching: query)) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(group.names, id: \.self) { name in
                                        cell(name)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(height: 260)
                // Open on the folder's own symbol rather than at the top of a
                // list it is three screens down in.
                .onAppear {
                    guard let current, FolderSymbolCatalogue.exists(current) else { return }
                    DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
                }
            }

            // Fixed: the grid scrolls behind it.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            )
            .padding(12)
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    /// Monochrome glyph on the popover's own ground; the current one is marked
    /// by a filled circle in the *system* accent — the user's colour, not the
    /// app's. The note list keeps the identity wash to itself.
    private func cell(_ name: String) -> some View {
        let selected = name == current
        return Button {
            choose(name)
        } label: {
            Image(systemName: name)
                .imageScale(.medium)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text(name))
    }
}
