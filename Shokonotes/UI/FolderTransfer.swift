import Foundation
import UniformTypeIdentifiers

/// A folder dragged inside the sidebar. The payload is a reference, never the
/// folder's content: the move itself is done on disk by `Actions`.
struct FolderTransfer: Codable, Hashable {
    let url: URL

    static func itemProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = (try? JSONEncoder().encode(FolderTransfer(url: url))) ?? Data()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.shokonotesFolder.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

extension UTType {
    static let shokonotesFolder = UTType(exportedAs: "com.jcbaptiste.shokonotes.folder-reference")
}
