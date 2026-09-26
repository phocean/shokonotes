import Foundation

enum LibraryError: LocalizedError, Equatable {
    case noRoot
    case nameExists(String)
    case renameFailed
    case invalidName
    case folderNotEmpty
    case sidecarWriteFailed
    case cannotRememberFolder
    case cannotOpenFolder
    case sampleLibraryMissing
    case sampleLibraryCopyFailed

    var errorDescription: String? {
        switch self {
        case .noRoot:
            return NSLocalizedString("No notes folder is selected.", comment: "")
        case .nameExists(let name):
            return String(format: NSLocalizedString("Note with name \"%@\" already exists in selected directory.", comment: ""), name)
        case .renameFailed:
            return NSLocalizedString("The note could not be renamed.", comment: "")
        case .invalidName:
            return NSLocalizedString("That name is not valid.", comment: "")
        case .folderNotEmpty:
            return NSLocalizedString("The folder could not be removed.", comment: "")
        case .sidecarWriteFailed:
            return NSLocalizedString("The library could not save its records.", comment: "")
        case .cannotRememberFolder:
            return NSLocalizedString("Shokonotes could not remember this notes folder.", comment: "")
        case .cannotOpenFolder:
            return NSLocalizedString("Shokonotes could not open this notes folder.", comment: "")
        case .sampleLibraryMissing:
            return NSLocalizedString("The sample library could not be found.", comment: "")
        case .sampleLibraryCopyFailed:
            return NSLocalizedString("The sample library could not be copied.", comment: "")
        }
    }
}
