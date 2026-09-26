import SwiftUI

extension AppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct IOSSettingsView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, session: IOSSession) {
        self.library = library
        self.session = session
    }

    var body: some View {
        NavigationStack {
            List {
                storageSection
                appearanceSection
                rowsSection
                sortSection
                previewSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var storageSection: some View {
        Section {
            if let name = library.rootURL?.lastPathComponent, !name.isEmpty {
                LabeledContent("Notes folder", value: name)
            }
            Button("Change…") { session.isPickingFolder = true }
            Button("Open Sample Library") {
                library.openSampleLibrary()
                session.path = []
            }
            Toggle("Resolve iCloud conflicts automatically", isOn: Binding(
                get: { settings.resolveICloudConflicts },
                set: {
                    settings.resolveICloudConflicts = $0
                    library.reloadFromDisk()
                }
            ))
            Picker("File extension", selection: Binding(
                get: { settings.noteExtension },
                set: { settings.noteExtension = $0 }
            )) {
                Text(".md").tag("md")
                Text(".markdown").tag("markdown")
                Text(".txt").tag("txt")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("The folder that holds your Markdown notes, in iCloud Drive.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { settings.appearance },
                set: { settings.appearance = $0 }
            )) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)
            Toggle("Show the inbox count on the app icon", isOn: Binding(
                get: { settings.showInboxBadge },
                set: {
                    settings.showInboxBadge = $0
                    InboxBadge.refresh()
                }
            ))
        }
    }

    private var rowsSection: some View {
        Section {
            Toggle("Show an excerpt", isOn: Binding(
                get: { settings.showExcerpt },
                set: { settings.showExcerpt = $0 }
            ))
            Toggle("Show the date", isOn: Binding(
                get: { settings.showDate },
                set: { settings.showDate = $0 }
            ))
            Toggle("Show tags", isOn: Binding(
                get: { settings.showTagsInList },
                set: { settings.showTagsInList = $0 }
            ))
            Toggle("Use the first line as the title", isOn: Binding(
                get: { settings.useFirstLineAsTitle },
                set: {
                    settings.useFirstLineAsTitle = $0
                    library.reloadFromDisk()
                }
            ))
        } header: {
            Text("Rows")
        } footer: {
            Text("When a note has no YAML title, the first line of the body is used. Off: the file name.")
        }
    }

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort notes by", selection: Binding(
                get: { library.sortBy },
                set: { library.sortBy = $0 }
            )) {
                Text("Modification Date").tag(SortKey.modified)
                Text("Creation Date").tag(SortKey.created)
                Text("Title").tag(SortKey.title)
            }
            Toggle("Ascending", isOn: Binding(
                get: { library.sortAscending },
                set: { library.sortAscending = $0 }
            ))
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Picker("Theme", selection: Binding(
                get: { settings.previewTheme },
                set: { settings.previewTheme = $0 }
            )) {
                ForEach(PreviewTheme.allCases) { theme in
                    Text(LocalizedStringKey(theme.title)).tag(theme)
                }
            }
            Picker("Font", selection: Binding(
                get: { settings.previewFont },
                set: { settings.previewFont = $0 }
            )) {
                ForEach(PreviewFont.allCases) { font in
                    Text(LocalizedStringKey(font.title)).tag(font)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(settings.previewFontSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.previewFontSize) },
                        set: { settings.previewFontSize = Int($0) }
                    ),
                    in: 14...22,
                    step: 1
                )
            }
            Picker("Line spacing", selection: Binding(
                get: { settings.previewLineHeight },
                set: { settings.previewLineHeight = $0 }
            )) {
                ForEach(PreviewLineHeight.allCases) { height in
                    Text(LocalizedStringKey(height.title)).tag(height)
                }
            }
            Picker("Width", selection: Binding(
                get: { settings.previewMeasure },
                set: { settings.previewMeasure = $0 }
            )) {
                ForEach(PreviewMeasure.allCases) { measure in
                    Text(LocalizedStringKey(measure.title)).tag(measure)
                }
            }
            Toggle("Show the title above the note", isOn: Binding(
                get: { settings.previewShowTitle },
                set: { settings.previewShowTitle = $0 }
            ))
            Picker("Images", selection: Binding(
                get: { settings.previewImages },
                set: { settings.previewImages = $0 }
            )) {
                ForEach(PreviewImageSize.allCases) { size in
                    Text(LocalizedStringKey(size.title)).tag(size)
                }
            }
            Toggle("Preserve line breaks", isOn: Binding(
                get: { settings.previewHardBreaks },
                set: { settings.previewHardBreaks = $0 }
            ))
            Toggle("Smart punctuation", isOn: Binding(
                get: { settings.previewSmartPunctuation },
                set: { settings.previewSmartPunctuation = $0 }
            ))
        }
    }
}
