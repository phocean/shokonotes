import Foundation

/// What the engine offers when a tag being typed is a near-duplicate of one
/// the library already has. An offer, never a rewrite: the human's own tag is
/// his, and only he replaces it.
struct TagDuplicateOffer: Hashable, Sendable {
    /// What the human is typing.
    let typed: String
    /// The tag already in the library that it collides with.
    let existing: String
    /// Which fold made them collide. The UI may phrase the offer differently
    /// per kind; it never has to.
    let kind: Kind

    enum Kind: Hashable, Sendable {
        /// Same letters once case and accents are folded (`Projet` / `projet`,
        /// `ete` / `été`).
        case caseOrAccents
        /// Same word once a plural marker is folded too (`projet` / `projets`).
        case singularOrPlural
    }
}

/// The same statistics pass as `TagSuggestions`, at the moment a duplicate is
/// born — prevention, not an audit afterwards. Pure, no state, no disk.
enum TagHygiene {
    /// The existing tag that `typed` nearly duplicates, or nil.
    ///
    /// Nil when `typed` is empty, when it already *is* one of the existing
    /// tags (spelled exactly the same — nothing to offer), or when nothing
    /// collides. An exact case/accent collision wins over a plural one, and
    /// among equals the alphabetically first tag is chosen so the answer never
    /// depends on dictionary order.
    static func nearDuplicate(of typed: String, among existing: [String]) -> TagDuplicateOffer? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !existing.contains(trimmed) else { return nil }

        let folded = NoteSnapshot.fold(trimmed)
        let stem = stemmed(folded)
        var exact: [String] = []
        var plural: [String] = []

        for candidate in existing {
            let candidateFolded = NoteSnapshot.fold(candidate)
            if candidateFolded == folded {
                exact.append(candidate)
            } else if stemmed(candidateFolded) == stem {
                plural.append(candidate)
            }
        }

        let ordered: (String, String) -> Bool = {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if let match = exact.sorted(by: ordered).first {
            return TagDuplicateOffer(typed: trimmed, existing: match, kind: .caseOrAccents)
        }
        if let match = plural.sorted(by: ordered).first {
            return TagDuplicateOffer(typed: trimmed, existing: match, kind: .singularOrPlural)
        }
        return nil
    }

    /// One trailing plural marker removed from an already folded word, so that
    /// `projets`, `cities` and `boxes` land on the same key as their singular.
    /// Deliberately crude, and deliberately not a stemmer: it decides whether
    /// to *offer* a tag, never whether to change one. Irregular plurals
    /// (`travaux`, `souris`) are simply missed, which costs an offer — never a
    /// wrong rewrite.
    static func stemmed(_ folded: String) -> String {
        guard folded.count > 2 else { return folded }
        if folded.hasSuffix("ies") {
            return String(folded.dropLast(3)) + "y"
        }
        if folded.hasSuffix("es"), folded.count > 3 {
            let beforeES = folded[folded.index(folded.endIndex, offsetBy: -3)]
            // `boxes` → `box`, but not `notes` → `not`.
            if "sxzh".contains(beforeES) {
                return String(folded.dropLast(2))
            }
        }
        if folded.hasSuffix("s") {
            return String(folded.dropLast())
        }
        return folded
    }
}
