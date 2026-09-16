import Foundation
import CoreGraphics
import ImageIO

/// Median-cut colour quantisation, used to shrink PNGs without touching their dimensions.
///
/// PNG is lossless, so the only levers for hitting a byte cap are palette size and pixel
/// count. Reducing the palette is almost always the better trade: a 256-colour logo or menu
/// graphic is visually identical to the 16-million-colour original and a fraction of the size,
/// whereas downscaling is immediately visible. We only fall back to downscaling when even a
/// 2-colour palette will not fit.
enum Quantizer {

    /// RGBA8 pixel buffer pulled out of a CGImage so we can work on raw bytes.
    struct Bitmap {
        var pixels: [UInt8]   // RGBA, 4 bytes per pixel
        var width: Int
        var height: Int
    }

    static func bitmap(from image: CGImage) -> Bitmap? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return Bitmap(pixels: buf, width: w, height: h)
    }

    // MARK: - Median cut

    private struct Box {
        var colors: [SIMD3<Int>]
        var rMin = 0, rMax = 255, gMin = 0, gMax = 255, bMin = 0, bMax = 255

        mutating func shrink() {
            guard !colors.isEmpty else { return }
            rMin = 255; rMax = 0; gMin = 255; gMax = 0; bMin = 255; bMax = 0
            for c in colors {
                rMin = min(rMin, c.x); rMax = max(rMax, c.x)
                gMin = min(gMin, c.y); gMax = max(gMax, c.y)
                bMin = min(bMin, c.z); bMax = max(bMax, c.z)
            }
        }

        var longestAxis: Int {
            let dr = rMax - rMin, dg = gMax - gMin, db = bMax - bMin
            if dr >= dg && dr >= db { return 0 }
            if dg >= db { return 1 }
            return 2
        }

        var volume: Int { (rMax - rMin + 1) * (gMax - gMin + 1) * (bMax - bMin + 1) }

        var average: SIMD3<Int> {
            guard !colors.isEmpty else { return SIMD3(0, 0, 0) }
            var r = 0, g = 0, b = 0
            for c in colors { r += c.x; g += c.y; b += c.z }
            let n = colors.count
            return SIMD3(r / n, g / n, b / n)
        }
    }

    /// Build a palette of at most `count` colours from a sample of the image.
    ///
    /// Sampling keeps this fast on very large images — a few tens of thousands of pixels
    /// describe the colour distribution of a 36-megapixel photo perfectly well.
    static func palette(for bm: Bitmap, count: Int, sampleLimit: Int = 40_000) -> [SIMD3<Int>] {
        let total = bm.width * bm.height
        let stride = max(1, total / sampleLimit)

        var samples: [SIMD3<Int>] = []
        samples.reserveCapacity(min(total, sampleLimit) + 1)
        var i = 0
        while i < total {
            let p = i * 4
            // Skip near-transparent pixels; they should not pull the palette around.
            if bm.pixels[p + 3] > 8 {
                samples.append(SIMD3(Int(bm.pixels[p]), Int(bm.pixels[p + 1]), Int(bm.pixels[p + 2])))
            }
            i += stride
        }
        guard !samples.isEmpty else { return [SIMD3(0, 0, 0)] }

        var first = Box(colors: samples)
        first.shrink()
        var boxes = [first]

        // Repeatedly split the box with the largest colour volume.
        while boxes.count < count {
            guard let idx = boxes.enumerated()
                .filter({ $0.element.colors.count > 1 })
                .max(by: { $0.element.volume < $1.element.volume })?.offset
            else { break }

            var box = boxes[idx]
            let axis = box.longestAxis
            box.colors.sort { a, b in
                switch axis {
                case 0:  return a.x < b.x
                case 1:  return a.y < b.y
                default: return a.z < b.z
                }
            }
            let mid = box.colors.count / 2
            guard mid > 0 else { break }

            var lo = Box(colors: Array(box.colors[..<mid]))
            var hi = Box(colors: Array(box.colors[mid...]))
            lo.shrink(); hi.shrink()

            boxes.remove(at: idx)
            boxes.append(lo)
            boxes.append(hi)
        }

        return boxes.map(\.average)
    }

    /// Map every pixel to its nearest palette entry.
    ///
    /// Exact nearest-neighbour over millions of pixels would be slow, so we memoise results
    /// in a coarse 32×32×32 RGB grid — neighbouring colours map to the same entry anyway.
    static func indexed(_ bm: Bitmap, palette pal: [SIMD3<Int>]) -> [UInt8] {
        let total = bm.width * bm.height
        var out = [UInt8](repeating: 0, count: total)
        var cache = [Int16](repeating: -1, count: 32 * 32 * 32)

        for i in 0..<total {
            let p = i * 4
            let r = Int(bm.pixels[p]), g = Int(bm.pixels[p + 1]), b = Int(bm.pixels[p + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)

            if cache[key] >= 0 {
                out[i] = UInt8(cache[key])
                continue
            }
            var best = 0, bestDist = Int.max
            for (j, c) in pal.enumerated() {
                let dr = r - c.x, dg = g - c.y, db = b - c.z
                // Luma-weighted distance: the eye is most sensitive to green, least to blue.
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if d < bestDist { bestDist = d; best = j }
            }
            cache[key] = Int16(best)
            out[i] = UInt8(best)
        }
        return out
    }

    /// Encode as a true palette PNG. Returns nil if the image needs an alpha channel,
    /// since an indexed CGImage cannot carry one.
    static func encodeIndexedPNG(_ bm: Bitmap, colors: Int) -> Data? {
        let pal = palette(for: bm, count: min(256, max(2, colors)))
        guard !pal.isEmpty else { return nil }

        var table = [UInt8]()
        table.reserveCapacity(pal.count * 3)
        for c in pal { table += [UInt8(clamping: c.x), UInt8(clamping: c.y), UInt8(clamping: c.z)] }

        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let space = CGColorSpace(indexedBaseSpace: base, last: pal.count - 1, colorTable: table)
        else { return nil }

        let idx = indexed(bm, palette: pal)
        guard let provider = CGDataProvider(data: Data(idx) as CFData),
              let image = CGImage(width: bm.width, height: bm.height,
                                  bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: bm.width, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        return Engine.encode(image, as: .png, quality: 1.0)
    }

    /// Whether this image looks like flat artwork (logo, menu, screenshot, chart) rather
    /// than a photograph.
    ///
    /// This decides which quality we sacrifice first. Flat artwork survives palette
    /// reduction almost invisibly, so we keep its pixels and cut colours. Photographs band
    /// badly on gradients, so for those a smaller truecolour image beats a large posterised
    /// one. The test is simply how many distinct colours a sample contains: artwork reuses
    /// the same handful of colours across thousands of pixels, a photograph almost never
    /// repeats one.
    static func isFlatArtwork(_ bm: Bitmap) -> Bool {
        let total = bm.width * bm.height
        let sampleLimit = 20_000
        let stride = max(1, total / sampleLimit)

        var seen = Set<UInt32>()
        var counted = 0
        var i = 0
        while i < total {
            let p = i * 4
            if bm.pixels[p + 3] > 8 {
                let key = UInt32(bm.pixels[p]) << 16 | UInt32(bm.pixels[p + 1]) << 8 | UInt32(bm.pixels[p + 2])
                seen.insert(key)
                counted += 1
            }
            i += stride
        }
        guard counted > 200 else { return true }   // tiny images: palette is safe
        return seen.count * 8 < counted
    }

    /// Largest palette that still fits under the cap, at full resolution.
    ///
    /// Size grows monotonically with palette size, so this is the same binary search we
    /// use for JPEG quality — just over colour count instead.
    static func searchPalette(_ image: CGImage, maxBytes: Int) -> (data: Data, colors: Int)? {
        guard let bm = bitmap(from: image) else { return nil }

        var lo = 2, hi = 256
        var best: (Data, Int)?

        while lo <= hi {
            let mid = (lo + hi) / 2
            guard let data = encodeIndexedPNG(bm, colors: mid) else { break }
            if data.count <= maxBytes {
                best = (data, mid)
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let best else { return nil }
        return (data: best.0, colors: best.1)
    }
}
