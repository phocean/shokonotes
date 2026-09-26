import Foundation

/// Why a folder drop was refused. Cases are localized in the UI.
enum FolderMoveError: Error, Equatable {
    /// The destination is the dragged folder itself, or one of its descendants.
    case intoDescendant
    /// A folder with the same name already exists at the destination.
    /// Never overwrite, never merge. Payload is the folder name.
    case nameExists(String)
    /// The destination is already the folder's parent; the move is a no-op.
    case noChange
    /// The source is not a folder, or the destination is not an existing folder.
    case invalidDestination
}

/// Folder-level operations that are not note edits. A folder move is a real
/// move on disk: no Markdown body and no YAML front matter is ever rewritten.
enum FolderActions {

    /// Validates a folder drop and returns the URL the folder would occupy.
    /// Throws `FolderMoveError` for every refusal; performs no disk change.
    static func plannedDestination(
        moving folder: URL,
        into destination: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = folder.standardizedFileURL
        let parent = destination.standardizedFileURL

        guard isDirectory(source, fileManager: fileManager),
              isDirectory(parent, fileManager: fileManager) else {
            throw FolderMoveError.invalidDestination
        }

        // Directory boundary, never a raw hasPrefix. Covers a drop on itself.
        if LibraryPaths.isInside(parent, folder: source) {
            throw FolderMoveError.intoDescendant
        }

        if source.deletingLastPathComponent().standardizedFileURL == parent {
            throw FolderMoveError.noChange
        }

        let name = source.lastPathComponent
        let target = parent.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            throw FolderMoveError.nameExists(name)
        }
        return target.standardizedFileURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}
