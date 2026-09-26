import SwiftUI

struct IOSRootView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.needsRestore {
                LibraryOpeningView()
            } else if library.rootURL == nil {
                FolderOnboardingView(
                    onChoose: { session.isPickingFolder = true },
                    onOpenSample: { library.openSampleLibrary() }
                )
                .shokoFolderImporter(session: session)
            } else {
                LibraryListView(session: session, library: library)
            }
        }
        .preferredColorScheme(settings.appearance.preferredColorScheme)
        .task {
            await session.restoreIfNeeded()
            InboxBadge.refresh()
        }
        .onOpenURL { session.handleOpenURL($0) }
        .sheet(item: $session.sheet) { item in
            switch item {
            case .capture:
                CaptureSheet(library: library) {
                    session.dismissCapture()
                }
            case .settings:
                IOSSettingsView(library: library, session: session)
                    .shokoFolderImporter(session: session)
            }
        }
        .alert(
            "Shokonotes",
            isPresented: Binding(
                get: { session.alertMessage != nil },
                set: { if !$0 { session.alertMessage = nil } }
            )
        ) {
            Button("Done", role: .cancel) { session.alertMessage = nil }
        } message: {
            Text(session.alertMessage ?? "")
        }
        .onChange(of: library.reloadCount) { _, _ in
            InboxBadge.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.reloadIfActive()
                InboxBadge.refresh()
            }
        }
        .task(id: pollKey) {
            guard pollKey else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                library.reloadFromDisk()
                InboxBadge.refresh()
            }
        }
    }

    /// Poll only while the scene is active and a library is already open.
    /// Become-active still reloads immediately (share ingest + rescan).
    private var pollKey: Bool {
        scenePhase == .active && !session.needsRestore && library.rootURL != nil
    }

    private static let pollInterval: Duration = .seconds(15)
}

struct LibraryOpeningView: View {
    var body: some View {
        ProgressView("Opening library…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FolderOnboardingView: View {
    var onChoose: () -> Void
    var onOpenSample: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Shokonotes")
                .font(.largeTitle.weight(.semibold))
            Text("Pick the iCloud Drive folder that holds your notes. Other Files locations are not supported.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button(action: onChoose) {
                Text("Choose Folder…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.top, 8)
            Button("Open Sample Library", action: onOpenSample)
                .controlSize(.large)
            Spacer()
        }
    }
}


