import Foundation
import UniformTypeIdentifiers

/// A tag dragged inside the sidebar. The payload is a name, never a folder
/// or a note: it is only a favourite (or a refuse), never a move on disk.
struct TagTransfer: Codable, Hashable {
    let name: String
}

extension UTType {
    static let shokonotesTag = UTType(exportedAs: "com.jcbaptiste.shokonotes.tag-reference")
}
