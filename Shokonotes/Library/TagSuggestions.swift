import Foundation

/// Why a tag is suggested. A typed value, never a sentence: the engine has no
/// language, the UI localizes these into at most three words
/// ("in the text", "this folder", "with #client").
///
/// There is deliberately no `recentlyUsed` case. Recency is real but it
/// explains nothing on screen — it only boosts a tag that another signal
/// already justifies (see `TagSuggestions`).
enum TagSuggestionReason: Hashable, Sendable {
    /// The tag is written, as a word, in the note's title or body.
    case inText
    /// The tag is carried by at least half of the note's own folder.
    case thisFolder
    /// Notes carrying `tag` — a tag this note already has — usually carry this
    /// one too. The associated value is that companion tag, without its `#`.
    case withTag(String)
}

/// One suggested tag and the single reason the UI shows next to it.
struct TagSuggestion: Hashable, Sendable, Identifiable {
    var id: String { tag }
    let tag: String
    /// The strongest signal behind the suggestion — what the UI renders.
    let reason: TagSuggestionReason
    /// The summed score. Exposed for tests and ordering, not for display.
    let score: Double
}

/// Counting over the library the user already has: no model, no learning, no
/// network, no state, no disk. `suggest` is pure — the same inputs give the
/// same answer, which is why it is testable without a temporary folder.
///
/// Four signals are summed and capped, and a candidate under `threshold` is
/// simply not returned. Returning fewer than five — or none at all — is the
/// feature: a header over filler is the intrusion this design avoids.
enum TagSuggestions {
    // MARK: - The numbers, and why they are these numbers

    /// Never more than five, however good the library is.
    static let maximumCount = 5

    /// A suggestion has to be worth a line in a popover. The threshold sits
    /// just under the literal signal, so a tag written in the text always
    /// qualifies on its own and every other signal has to be near-unanimous
    /// (or be joined by a second signal) to earn its place.
    static let threshold = 0.8

    /// The tag is a word of the title or body. The strongest thing counting
    /// can know: the human already wrote it.
    static let literalWeight = 1.0

    /// A tag carried by *most* of the folder. Scaled by the share, so a
    /// folder where every note is `#recipe` scores 0.9 and a bare majority
    /// scores 0.45 — which alone stays under the threshold.
    static let folderWeight = 0.9

    /// Same shape as the folder signal, over the notes that carry a tag this
    /// note already has.
    static let coOccurrenceWeight = 0.9

    /// A booster, never a reason. It cannot reach the threshold by itself
    /// (0.5 < 0.8) because "you used it lately" is not something the app can
    /// defend in three words.
    static let recencyWeight = 0.5

    /// Below this share the folder (or the companion tag) is not dominant,
    /// it is merely present — and present says nothing.
    static let dominanceFloor = 0.5

    /// Under this many notes, co-occurrence is noise: three notes sharing two
    /// tags is a coincidence, not a habit. The lot's spec says ~30.
    static let coOccurrenceMinimumNotes = 30

    /// A folder needs a few notes before "most of this folder" means anything.
    static let folderMinimumNotes = 3

    /// How far back "recently used" looks, in notes ordered by modification.
    static let recencyWindow = 20

    /// Literal matching ignores one- and two-letter tags: too many accidental
    /// words, and the match would explain nothing.
    static let literalMinimumLength = 3

    // MARK: - The one entry point

    /// At most `maximumCount` tags for `note`, strongest first. Empty when
    /// nothing clears `threshold`.
    ///
    /// - Parameters:
    ///   - note: the note whose tag editor is open.
    ///   - library: every note of the library. Trashed notes and `note` itself
    ///     are ignored; the caller does not have to filter them out.
    static func suggest(
        for note: NoteSnapshot,
        in library: [NoteSnapshot],
        limit: Int = TagSuggestions.maximumCount
    ) -> [TagSuggestion] {
        let corpus = library.filter { !$0.isTrashed && $0.url != note.url }
        let owned = Set(note.tags.map(NoteSnapshot.fold))
        var candidates = Set<String>()
        for other in corpus where !other.tags.isEmpty {
            for tag in other.tags where !owned.contains(NoteSnapshot.fold(tag)) {
                candidates.insert(tag)
            }
        }
        guard !candidates.isEmpty else { return [] }

        let folderShares = shares(
            in: corpus.filter { $0.folderURL.standardizedFileURL == note.folderURL.standardizedFileURL },
            minimum: folderMinimumNotes
        )
        let recency = recencyScores(in: corpus)
        // Under ~30 notes co-occurrence says nothing: literal + recency (+ the
        // folder, which is a count of a folder, not of the library) carry the
        // fallback.
        let companions: [String: [String: Double]] = corpus.count >= coOccurrenceMinimumNotes
            ? coOccurrenceShares(for: note, in: corpus)
            : [:]

        var results: [TagSuggestion] = []
        for tag in candidates {
            var score = 0.0
            var reason: TagSuggestionReason?
            var best = 0.0

            if tag.count >= literalMinimumLength,
               containsWord(NoteSnapshot.fold(tag), in: note.searchHaystack) {
                score += literalWeight
                best = literalWeight
                reason = .inText
            }

            if let share = folderShares[tag], share >= dominanceFloor {
                let value = folderWeight * share
                score += value
                if value > best {
                    best = value
                    reason = .thisFolder
                }
            }

            var bestCompanion: (tag: String, value: Double)?
            for (companion, shares) in companions {
                guard let share = shares[tag], share >= dominanceFloor else { continue }
                let value = coOccurrenceWeight * share
                if value > (bestCompanion?.value ?? 0) {
                    bestCompanion = (companion, value)
                }
            }
            if let bestCompanion {
                score += bestCompanion.value
                if bestCompanion.value > best {
                    best = bestCompanion.value
                    reason = .withTag(bestCompanion.tag)
                }
            }

            score += (recency[tag] ?? 0) * recencyWeight

            guard let reason, score >= threshold else { continue }
            results.append(TagSuggestion(tag: tag, reason: reason, score: score))
        }

        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
        return Array(results.prefix(max(0, limit)))
    }

    // MARK: - Signals

    /// Tag → share of `notes` carrying it. Empty when there are too few notes
    /// for a share to mean anything.
    private static func shares(in notes: [NoteSnapshot], minimum: Int) -> [String: Double] {
        guard notes.count >= minimum else { return [:] }
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in Set(note.tags) { counts[tag, default: 0] += 1 }
        }
        let total = Double(notes.count)
        return counts.mapValues { Double($0) / total }
    }

    /// For each tag the note already carries: tag → share of the notes
    /// carrying it that also carry each candidate.
    private static func coOccurrenceShares(
        for note: NoteSnapshot,
        in corpus: [NoteSnapshot]
    ) -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for owned in Set(note.tags) {
            let carriers = corpus.filter { $0.tags.contains(owned) }
            let shares = shares(in: carriers, minimum: folderMinimumNotes)
            guard !shares.isEmpty else { continue }
            var others = shares
            others.removeValue(forKey: owned)
            result[owned] = others
        }
        return result
    }

    /// Tag → 1.0 for the tags of the most recently modified note, decaying to
    /// nearly 0 at the end of the window. A tag keeps its best (most recent)
    /// position.
    private static func recencyScores(in corpus: [NoteSnapshot]) -> [String: Double] {
        // Equal dates are common (a freshly copied library), and Swift's sort
        // is not stable: the path breaks the tie so the answer never depends
        // on dictionary order.
        let recent = corpus
            .sorted {
                $0.modifiedAt == $1.modifiedAt
                    ? $0.url.path < $1.url.path
                    : $0.modifiedAt > $1.modifiedAt
            }
            .prefix(recencyWindow)
        guard !recent.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        let window = Double(recencyWindow)
        for (index, note) in recent.enumerated() {
            let weight = 1.0 - Double(index) / window
            for tag in note.tags where (result[tag] ?? 0) < weight {
                result[tag] = weight
            }
        }
        return result
    }

    // MARK: - Literal matching

    /// `needle` appears in `haystack` bounded by non-alphanumerics, so `art`
    /// does not match `start`. Both sides are already folded.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let afterOK = found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.lowerBound < haystack.endIndex else { return false }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
