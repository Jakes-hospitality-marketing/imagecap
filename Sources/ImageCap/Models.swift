import Foundation
import UniformTypeIdentifiers

/// How aggressively we were forced to work to meet the byte cap.
/// Ordered from best to worst so the UI can sort attention to the bottom of the list.
enum Treatment: Int, Comparable {
    case copied          // already under the cap, passed through untouched
    case recompressed    // re-encoded at a lower quality, same pixel dimensions
    case resized         // pixel dimensions reduced to make the cap
    case converted       // format changed (WebP in, since macOS cannot write WebP)
    case failed

    static func < (a: Treatment, b: Treatment) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .copied:       return "Already small enough"
        case .recompressed: return "Compressed"
        case .resized:      return "Compressed + resized"
        case .converted:    return "Converted"
        case .failed:       return "Failed"
        }
    }
}

struct Settings {
    var maxBytes: Int = 1_900_000
    /// Optional ceiling on the longest edge, applied before any quality search.
    var maxDimension: Int? = nil
    var stripMetadata: Bool = true

    /// Quality we refuse to go below before we start shrinking dimensions instead.
    ///
    /// Without a floor, a large image squeezed into a small cap comes out full-size and
    /// smeared. Past roughly this point a smaller, cleaner image reads better than a
    /// blurry one at full dimensions. The cap is always met either way.
    var minQuality: Double = 0.40

    /// Deliberately a notch under the round numbers these limits are quoted as.
    /// An upload limit of "2 MB" is a hard ceiling, and platforms disagree about whether
    /// a megabyte is 1,000,000 or 1,048,576 bytes — landing at exactly 2 MB risks a
    /// rejected upload. The headroom costs nothing visible.
    static let presets: [(String, Int)] = [
        ("1.9 MB", 1_900_000),
        ("3.9 MB", 3_900_000),
        ("900 KB", 900_000),
        ("450 KB", 450_000),
    ]
}

struct Result: Identifiable {
    let id = UUID()
    let source: URL
    var output: URL?
    var originalBytes: Int
    var finalBytes: Int
    var originalPixels: (w: Int, h: Int)
    var finalPixels: (w: Int, h: Int)
    var quality: Double?
    var treatment: Treatment
    var note: String?

    var saved: Double {
        guard originalBytes > 0, finalBytes < originalBytes else { return 0 }
        return 1.0 - (Double(finalBytes) / Double(originalBytes))
    }
}

func formatBytes(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0f KB", Double(n) / 1_000) }
    return "\(n) B"
}

/// Extensions we will pick up when the user drops a folder.
let supportedExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "avif", "bmp",
]
