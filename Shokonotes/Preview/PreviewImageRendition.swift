import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Turns a note's local image into the `data:` URI the preview document
/// carries, and says — without reading a single byte — what the cache key for
/// that payload would be.
///
/// Two properties are the whole point of this type:
///
/// 1. **Nothing is written anywhere.** ImageIO decodes the original
///    *subsampled* straight to the target size, the JPEG is encoded into an
///    in-memory `CFMutableData`, and the base64 lands in `PreviewImageCache`.
///    No temp file, nothing in the user's library, nothing in `.shokonotes/` —
///    FSEvents and iCloud see nothing. That is the property `loadFileURL`
///    could not offer, and it is why the document stays self-contained (a
///    passage copied out of the preview pastes with its image).
/// 2. **`descriptor(for:target:)` only stats.** It is the half that is allowed
///    to run on the main thread; `payload(for:)` is the half that reads and
///    encodes, and it must not.
enum PreviewImageRendition {
    /// Above this an image is not inlined byte for byte any more: it is
    /// replaced by a downscaled JPEG rendition. Below it the original travels
    /// untouched, so a screenshot is pixel for pixel what it is.
    static let inlineByteLimit = 2 * 1024 * 1024

    /// How wide, in pixels, the longest edge of a rendition may be.
    enum Target: Sendable {
        /// The preview pane. The stylesheet caps the text column near 44em
        /// (~700 pt) and an image at `max-width: 100%` of it; 2048 covers that
        /// column on a Retina display (2x) with room for a window dragged
        /// wider than the measure, and no more — extra pixels past what the
        /// pane can show are bytes the main thread would have waited for.
        case screen
        /// Print and PDF export. `PreviewPageRenderer.pageBox` is 800 pt wide
        /// at 96 dpi; the same page at 300 dpi is 2500 px, and a full-page
        /// photo should have pixels left over rather than exactly enough, so
        /// the wide rendition is 3072. He chose the wide rendition for export
        /// on 2026-09-13: paper keeps detail the screen never needed.
        case print

        var maxPixelSize: Int {
            switch self {
            case .screen: return 2048
            case .print: return 3072
            }
        }

        /// The part of the cache key that says which rendition this is.
        var cacheToken: String {
            switch self {
            case .screen: return "screen-\(maxPixelSize)"
            case .print: return "print-\(maxPixelSize)"
            }
        }
    }

    /// Everything known about an image from a `stat` and its file extension:
    /// enough to decide whether it is inlineable at all and to name the cache
    /// entry, and cheap enough to do during a click.
    struct Descriptor: Sendable {
        let url: URL
        /// The original's MIME type. The rendition's own type is JPEG.
        let mime: String
        let byteSize: Int
        let modified: TimeInterval
        /// nil for an original inlined byte for byte — the payload does not
        /// depend on the target, so both targets share one cache entry.
        let target: Target?

        var isRendition: Bool { target != nil }

        /// Path + mtime + size, so an image edited on disk is re-read rather
        /// than frozen in, plus the target pixel size so the screen rendition
        /// and the wider print one never collide.
        var cacheKey: String {
            "\(url.path)|\(modified)|\(byteSize)|\(target?.cacheToken ?? "original")"
        }
    }

    /// Metadata only — one `stat` and a `UTType` lookup, no bytes read. nil
    /// means "do not inline": a missing file, an empty one, a non-image, or a
    /// type the system cannot name (`application/octet-stream` is a payload no
    /// engine paints).
    static func descriptor(for url: URL, target: Target) -> Descriptor? {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let mime = type.preferredMIMEType else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0 else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return Descriptor(
            url: url,
            mime: mime,
            byteSize: size,
            modified: modified,
            target: size <= inlineByteLimit ? nil : target
        )
    }

    /// The cached payload, or nil if it has not been built. Never reads the
    /// file: this is the lookup a main-thread render is allowed to do.
    static func cached(_ descriptor: Descriptor) -> String? {
        PreviewImageCache.shared.cached(for: descriptor.cacheKey)
    }

    /// Reads and encodes. **Never call this on the main thread** — it is the
    /// `Data(contentsOf:)` and the JPEG encode the 2 MiB cap used to bound.
    @discardableResult
    static func payload(for descriptor: Descriptor) -> String? {
        if let cached = cached(descriptor) { return cached }
        let built: String?
        if let target = descriptor.target {
            built = renditionURI(for: descriptor.url, target: target)
        } else {
            built = originalURI(for: descriptor)
        }
        guard let built else { return nil }
        PreviewImageCache.shared.store(built, for: descriptor.cacheKey)
        return built
    }

    /// The original, byte for byte, in its own type.
    private static func originalURI(for descriptor: Descriptor) -> String? {
        guard let data = try? Data(contentsOf: descriptor.url) else { return nil }
        return "data:\(descriptor.mime);base64,\(data.base64EncodedString())"
    }

    /// A downscaled JPEG built by ImageIO. `kCGImageSourceThumbnailMaxPixelSize`
    /// makes the decode itself subsampled — a 60 MiB TIFF is never fully
    /// decoded and then scaled, which is the difference between a rendition and
    /// a freeze. The result lives in a `CFMutableData`; nothing touches disk.
    private static func renditionURI(for url: URL, target: Target) -> String? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, sourceOptions as CFDictionary
        ) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target.maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

        guard let buffer = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                buffer, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return nil }
        // 0.82: the knee where a photographic rendition stops shrinking and
        // starts only losing. A 20 MiB scan lands in the low hundreds of KiB.
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return "data:image/jpeg;base64,\((buffer as Data).base64EncodedString())"
    }
}
