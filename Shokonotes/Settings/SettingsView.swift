import SwiftUI
import AppKit

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, storage, appearance, preview

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .storage: return "Storage"
            case .appearance: return "Appearance"
            case .preview: return "Preview"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            // The notes folder is a place the user points at — often iCloud
            // Drive or a volume — so `externaldrive`, not `internaldrive`,
            // which would assert a local disk the library need not live on.
            case .storage: return "externaldrive"
            case .appearance: return "paintbrush"
            case .preview: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            .frame(maxHeight: .infinity)

            Group {
                switch selection {
                case .general: GeneralSettings()
                case .storage: StorageSettings()
                case .appearance: AppearanceSettings()
                case .preview: PreviewSettings()
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        // No minimum here: the window owns the minimum size (contentMinSize in
        // SettingsWindowController). A min taller than the window's content view
        // makes NSHostingView centre an oversized view and clip its top rows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the library lives and how its files are named. Split out of General so
/// that the one pane a user opens to point the app at a folder is not also the
/// pane about windows, editors and shortcuts.
private struct StorageSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = LibraryModel.shared

    var body: some View {
        Form {
            SwiftUI.Section("Storage") {
                LabeledContent("Notes folder") {
                    HStack {
                        Text(model.rootURL?.path ?? "—")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Change…") { model.chooseStorageFolder() }
                    }
                }

                Button("Open Sample Library") { model.openSampleLibrary() }

                Text("New notes use a placeholder name on disk. Change the title and tags in Shokonotes. Rename the file here — never from the external editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Resolve iCloud conflicts automatically", isOn: Binding(
                    get: { settings.resolveICloudConflicts },
                    set: { settings.resolveICloudConflicts = $0 }
                ))

                Picker("File extension", selection: Binding(
                    get: { settings.noteExtension },
                    set: { settings.noteExtension = $0 }
                )) {
                    Text(".md").tag("md")
                    Text(".markdown").tag("markdown")
                    Text(".txt").tag("txt")
                }

                if let root = model.rootURL {
                    Button("Reveal notes folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                }
            }

            SwiftUI.Section("Hidden folders") {
                TextEditor(text: Binding(
                    get: { settings.attachmentFoldersText },
                    set: {
                        settings.attachmentFoldersText = $0
                        model.applyAttachmentFolderPatterns()
                    }
                ))
                .font(.body.monospaced())
                .frame(minHeight: 72, maxHeight: 120)
                Text("One folder name per line. These folders stay on disk and are omitted from the sidebar. A leading * matches a suffix, for example *.assets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SwiftUI.Section("Editing") {
                LabeledContent("External editor") {
                    HStack {
                        Text(ExternalEditors.displayName(for: settings.externalEditorBundle))
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let bundle = ExternalEditors.pickApplication() {
                                settings.externalEditorBundle = bundle
                            }
                        }
                    }
                }
                Toggle("Open the editor when creating a note", isOn: Binding(
                    get: { settings.openEditorOnCreate },
                    set: { settings.openEditorOnCreate = $0 }
                ))
                Text("Double-clicking a note opens it here. Shokonotes itself never edits note contents. The global quick-note shortcut always opens the editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Window") {
                Toggle("Quit Shokonotes when closing the library window", isOn: Binding(
                    get: { settings.quitOnWindowClose },
                    set: { settings.quitOnWindowClose = $0 }
                ))
            }

            SwiftUI.Section("Global shortcuts") {
                LabeledContent("Quick note") {
                    ShortcutRecorder(chord: Binding(
                        get: { settings.quickNoteShortcut },
                        set: { settings.quickNoteShortcut = $0 }
                    ))
                    .frame(width: 180, height: 24)
                }
                LabeledContent("Show or hide Shokonotes") {
                    ShortcutRecorder(chord: Binding(
                        get: { settings.activateShortcut },
                        set: { settings.activateShortcut = $0 }
                    ))
                    .frame(width: 180, height: 24)
                }
                Text("Quick note creates a note in the Inbox and opens your editor, from any app. Showing and hiding the library never quits Shokonotes. Click the field, then type a shortcut. Delete clears it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Last on purpose: a pane does not open on its least consequential
            // control.
            SwiftUI.Section("Folders") {
                Toggle("Show notes from subfolders", isOn: Binding(
                    get: { settings.includeFolderDescendants },
                    set: {
                        settings.includeFolderDescendants = $0
                        LibraryModel.shared.reloadNotes()
                    }
                ))
                Text("When a folder is selected, notes in nested folders are listed too. Inbox stays the files in the library root.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Theme", selection: Binding(
                    get: { settings.appearance },
                    set: { settings.appearance = $0 }
                )) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            SwiftUI.Section("Rows") {
                Toggle("Show an excerpt", isOn: Binding(
                    get: { settings.showExcerpt },
                    set: { settings.showExcerpt = $0; LibraryWindowController.notifyStorageChanged() }
                ))
                Toggle("Show the date", isOn: Binding(
                    get: { settings.showDate },
                    set: { settings.showDate = $0; LibraryWindowController.notifyStorageChanged() }
                ))
                Toggle("Show tags", isOn: Binding(
                    get: { settings.showTagsInList },
                    set: { settings.showTagsInList = $0; LibraryWindowController.notifyStorageChanged() }
                ))
                Toggle("Compact rows", isOn: Binding(
                    get: { settings.compactRows },
                    set: { settings.compactRows = $0; LibraryWindowController.notifyStorageChanged() }
                ))
                Toggle("Use the first line as the title", isOn: Binding(
                    get: { settings.useFirstLineAsTitle },
                    set: {
                        settings.useFirstLineAsTitle = $0
                        LibraryModel.shared.reloadFromDisk()
                    }
                ))
                Text("When a note has no YAML title, the first line of the body is used. Off: the file name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Sort") {
                Picker("Sort notes by", selection: Binding(
                    get: { settings.sortKey },
                    set: {
                        settings.sortKey = $0
                        LibraryModel.shared.reloadNotes()
                    }
                )) {
                    Text("Modification Date").tag(SortKey.modified)
                    Text("Creation Date").tag(SortKey.created)
                    Text("Title").tag(SortKey.title)
                }
                Toggle("Ascending", isOn: Binding(
                    get: { settings.sortAscending },
                    set: {
                        settings.sortAscending = $0
                        LibraryModel.shared.reloadNotes()
                    }
                ))
            }

            SwiftUI.Section("Dock") {
                Toggle("Show the inbox count on the Dock icon", isOn: Binding(
                    get: { settings.showInboxBadge },
                    set: { settings.showInboxBadge = $0 }
                ))
                Text("The Dock badge uses the system label. Unsigned local builds often cannot display it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PreviewSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SwiftUI.Section("Theme") {
                Picker("Theme", selection: Binding(
                    get: { settings.previewTheme },
                    set: { settings.previewTheme = $0 }
                )) {
                    ForEach(PreviewTheme.allCases) { theme in
                        Text(LocalizedStringKey(theme.title)).tag(theme)
                    }
                }
                Text("The preview theme changes colours and code highlighting. Files are not modified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Text") {
                Picker("Font", selection: Binding(
                    get: { settings.previewFont },
                    set: { settings.previewFont = $0 }
                )) {
                    ForEach(PreviewFont.allCases) { font in
                        Text(LocalizedStringKey(font.title)).tag(font)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(settings.previewFontSize) },
                                set: { settings.previewFontSize = Int($0) }
                            ),
                            in: 14...22,
                            step: 1
                        )
                        Text("\(settings.previewFontSize) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
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
            }

            SwiftUI.Section("Page") {
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
            }

            SwiftUI.Section("Markdown") {
                Toggle("Preserve line breaks", isOn: Binding(
                    get: { settings.previewHardBreaks },
                    set: { settings.previewHardBreaks = $0 }
                ))
                Text("Line breaks in the file become new lines in the preview. Off: standard Markdown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Smart punctuation", isOn: Binding(
                    get: { settings.previewSmartPunctuation },
                    set: { settings.previewSmartPunctuation = $0 }
                ))
                Text("Turns quotes and dashes into typographic forms in the preview only. Files are not modified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        }
    }
}
