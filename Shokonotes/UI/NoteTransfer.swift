import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct NoteTransfer: Codable, Transferable, Hashable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .shokonotesNote)
    }
}

extension UTType {
    static let shokonotesNote = UTType(exportedAs: "com.jcbaptiste.shokonotes.note-reference")
}
