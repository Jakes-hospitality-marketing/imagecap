import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum Engine {

    // MARK: - Format policy

    /// macOS can decode WebP but cannot encode it, so WebP inputs have to change
    /// format. Everything else round-trips to itself.
    static func outputType(for input: UTType, hasAlpha: Bool) -> (type: UTType, converted: Bool) {
        switch input {
        case .jpeg:  return (.jpeg, false)
        case .png:   return (.png, false)
        case .heic, .heif: return (.heic, false)
        case .tiff:  return (.tiff, false)
        case .gif:   return (.gif, false)
        default:
            if input.identifier == "public.avif" { return (input, false) }
            // WebP, BMP and anything else exotic: alpha decides the destination.
            return (hasAlpha ? .png : .jpeg, true)
        }
    }

    /// Formats where a quality dial actually does something.
    static func isLossy(_ type: UTType) -> Bool {
        type == .jpeg || type == .heic || type == .heif || type.identifier == "public.avif"
    }

    static func fileExtension(for type: UTType) -> String {
        type.preferredFilenameExtension ?? "img"
    }

    // MARK: - Loading

    struct Loaded {
        var image: CGImage
        var type: UTType
        var hasAlpha: Bool
    }

    static func load(_ url: URL) -> Loaded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let typeID = CGImageSourceGetType(src) as String? ?? ""
        let type = UTType(typeID) ?? .jpeg

        // EXIF orientation lives in metadata. Since we strip metadata on write, bake the
        // rotation into the pixels instead — otherwise phone photos come out sideways.
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let image = orientation == 1 ? raw : (applyOrientation(raw, orientation) ?? raw)

        let alphaInfo = image.alphaInfo
        let hasAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)

        return Loaded(image: image, type: type, hasAlpha: hasAlpha)
    }

    /// Redraw the image so that pixel order matches EXIF orientation 1.
    private static func applyOrientation(_ image: CGImage, _ orientation: UInt32) -> CGImage? {
        let w = image.width, h = image.height
        // Orientations 5-8 swap the axes.
        let swaps = orientation >= 5
        let outW = swaps ? h : w
        let outH = swaps ? w : h

        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var t = CGAffineTransform.identity
        switch orientation {
        case 2: t = CGAffineTransform(translationX: CGFloat(outW), y: 0).scaledBy(x: -1, y: 1)
        case 3: t = CGAffineTransform(translationX: CGFloat(outW), y: CGFloat(outH)).rotated(by: .pi)
        case 4: t = CGAffineTransform(translationX: 0, y: CGFloat(outH)).scaledBy(x: 1, y: -1)
        case 5: t = CGAffineTransform(translationX: CGFloat(outW), y: CGFloat(outH))
                    .rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
                    .translatedBy(x: 0, y: -CGFloat(outH))
        case 6: t = CGAffineTransform(translationX: CGFloat(outW), y: 0).rotated(by: .pi / 2)
        case 7: t = CGAffineTransform(translationX: 0, y: 0)
                    .rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case 8: t = CGAffineTransform(translationX: 0, y: CGFloat(outH)).rotated(by: -.pi / 2)
        default: break
        }

        ctx.concatenate(t)
        // After the transform we are drawing in the original (pre-swap) coordinate space.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Geometry

    static func scaled(_ image: CGImage, to factor: Double) -> CGImage? {
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        return resize(image, w: w, h: h)
    }

    static func resize(_ image: CGImage, w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// JPEG has no alpha channel; flatten onto white so transparency does not read as black.
    static func flatten(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Encoding

    static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil
        ) else { return nil }

        var opts: [CFString: Any] = [:]
        if isLossy(type) {
            opts[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - The quality search

    /// Highest quality whose encoded size still fits under `maxBytes`.
    ///
    /// Size is monotonic in quality, so this is a plain binary search. We check the
    /// top of the range first: if full quality already fits there is nothing to trade away.
    static func searchQuality(
        _ image: CGImage, type: UTType, maxBytes: Int, floor: Double = 0.0, iterations: Int = 8
    ) -> (data: Data, quality: Double)? {
        if let top = encode(image, as: type, quality: 1.0), top.count <= maxBytes {
            return (top, 1.0)
        }

        var lo = floor, hi = 1.0
        var best: (Data, Double)?

        // If the floor itself does not fit, there is no answer in this range — the caller
        // will shrink the image and try again.
        if floor > 0 {
            guard let atFloor = encode(image, as: type, quality: floor), atFloor.count <= maxBytes
            else { return nil }
            best = (atFloor, floor)
        }

        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            guard let data = encode(image, as: type, quality: mid) else { break }
            if data.count <= maxBytes {
                best = (data, mid)   // fits — reach for more quality
                lo = mid
            } else {
                hi = mid             // too big — back off
            }
        }

        if let best { return (data: best.0, quality: best.1) }

        // Even the floor of the quality range overflows the cap.
        return nil
    }

    /// Shrink pixel dimensions until the image fits, keeping quality as high as the cap allows.
    ///
    /// Used when the quality dial alone cannot reach the target, and as the only lever
    /// available for lossless formats like PNG. Binary searches the scale factor so we
    /// do not over-shrink: we want the largest image that fits, not the first one that does.
    static func searchScale(
        _ image: CGImage, type: UTType, maxBytes: Int, lossy: Bool, floor: Double = 0.0
    ) -> (data: Data, image: CGImage, quality: Double?)? {
        var lo = 0.02, hi = 1.0
        var best: (Data, CGImage, Double?)?

        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            guard let candidate = scaled(image, to: mid) else { break }

            let attempt: (Data, Double?)?
            if lossy {
                attempt = searchQuality(candidate, type: type, maxBytes: maxBytes, floor: floor)
                    .map { ($0.data, $0.quality) }
            } else if let data = encode(candidate, as: type, quality: 1.0), data.count <= maxBytes {
                attempt = (data, nil)
            } else {
                attempt = nil
            }

            if let (data, q) = attempt {
                best = (data, candidate, q)  // fits — try to keep more pixels
                lo = mid
            } else {
                hi = mid                      // still too big — shrink harder
            }
        }
        guard let best else { return nil }
        return (data: best.0, image: best.1, quality: best.2)
    }

    // MARK: - Per-file pipeline

    static func process(_ url: URL, settings: Settings, outputDir: URL) -> Result {
        let originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard let loaded = load(url) else {
            return Result(source: url, output: nil, originalBytes: originalBytes, finalBytes: 0,
                          originalPixels: (0, 0), finalPixels: (0, 0), quality: nil,
                          treatment: .failed, note: "Could not read this file")
        }

        var image = loaded.image
        let originalPixels = (w: image.width, h: image.height)
        let (outType, converted) = outputType(for: loaded.type, hasAlpha: loaded.hasAlpha)
        let lossy = isLossy(outType)

        // JPEG cannot carry alpha.
        if lossy && loaded.hasAlpha, let flat = flatten(image) { image = flat }

        // Apply the dimension ceiling before anything else — it is the cheapest byte win.
        var didResize = false
        if let maxDim = settings.maxDimension {
            let longest = max(image.width, image.height)
            if longest > maxDim {
                let factor = Double(maxDim) / Double(longest)
                if let s = scaled(image, to: factor) { image = s; didResize = true }
            }
        }

        let target = settings.maxBytes

        // Fast path: nothing to do. Only valid if we are not converting or resizing,
        // since either of those means the bytes on disk are not what we would ship.
        if !converted && !didResize && originalBytes > 0 && originalBytes <= target {
            let dest = uniqueURL(in: outputDir, base: url.deletingPathExtension().lastPathComponent,
                                 ext: url.pathExtension)
            try? FileManager.default.copyItem(at: url, to: dest)
            return Result(source: url, output: dest, originalBytes: originalBytes,
                          finalBytes: originalBytes, originalPixels: originalPixels,
                          finalPixels: originalPixels, quality: nil, treatment: .copied, note: nil)
        }

        var finalData: Data?
        var finalImage = image
        var quality: Double?
        var paletteColors: Int?
        var treatment: Treatment = didResize ? .resized : .recompressed

        if lossy {
            if let hit = searchQuality(image, type: outType, maxBytes: target,
                                       floor: settings.minQuality) {
                finalData = hit.data
                quality = hit.quality
            }
        } else {
            // Lossless: a straight re-encode is free (it also drops metadata), so try that first.
            if let data = encode(image, as: outType, quality: 1.0), data.count <= target {
                finalData = data
            } else if outType == .png && !loaded.hasAlpha,
                      let bm = Quantizer.bitmap(from: image),
                      Quantizer.isFlatArtwork(bm),
                      let hit = Quantizer.searchPalette(image, maxBytes: target) {
                // Flat artwork: cut colours, keep every pixel.
                finalData = hit.data
                paletteColors = hit.colors
            }
        }

        // Nothing else worked — give up pixels, holding quality at or above the floor.
        if finalData == nil {
            if let hit = searchScale(image, type: outType, maxBytes: target,
                                     lossy: lossy, floor: settings.minQuality) {
                finalData = hit.data
                finalImage = hit.image
                quality = hit.quality
                treatment = .resized
            }
        }

        // Last resort: drop the quality floor. The cap is a hard promise, so if an image is
        // extreme enough that even a tiny version cannot meet it at decent quality, we would
        // rather ship something ugly than nothing.
        if finalData == nil, lossy {
            if let hit = searchScale(image, type: outType, maxBytes: target, lossy: true, floor: 0) {
                finalData = hit.data
                finalImage = hit.image
                quality = hit.quality
                treatment = .resized
            }
        }

        guard let data = finalData else {
            return Result(source: url, output: nil, originalBytes: originalBytes, finalBytes: 0,
                          originalPixels: originalPixels, finalPixels: originalPixels,
                          quality: nil, treatment: .failed,
                          note: "Could not reach \(formatBytes(target)) for this image")
        }

        if converted { treatment = .converted }

        // Keep the original extension when the format has not changed, so ".jpg" does not
        // silently become ".jpeg" and break anyone's filename expectations.
        let ext = converted ? fileExtension(for: outType)
                            : (url.pathExtension.isEmpty ? fileExtension(for: outType)
                                                         : url.pathExtension.lowercased())
        let dest = uniqueURL(in: outputDir,
                             base: url.deletingPathExtension().lastPathComponent,
                             ext: ext)
        do {
            try data.write(to: dest)
        } catch {
            return Result(source: url, output: nil, originalBytes: originalBytes, finalBytes: 0,
                          originalPixels: originalPixels, finalPixels: originalPixels,
                          quality: nil, treatment: .failed, note: "Could not write to output folder")
        }

        var note: String?
        if converted {
            note = "\(loaded.type.preferredFilenameExtension?.uppercased() ?? "Source") "
                 + "cannot be written by macOS — saved as \(fileExtension(for: outType).uppercased())"
        } else if let colors = paletteColors {
            note = "Reduced to \(colors) colours to fit"
        }

        return Result(source: url, output: dest, originalBytes: originalBytes,
                      finalBytes: data.count, originalPixels: originalPixels,
                      finalPixels: (finalImage.width, finalImage.height),
                      quality: quality, treatment: treatment, note: note)
    }

    /// Create a fresh folder, adding a numeric suffix rather than reusing an existing one.
    static func makeUniqueDirectory(in parent: URL, named base: String) -> URL? {
        var candidate = parent.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            return candidate
        } catch {
            return nil
        }
    }

    /// Never clobber an existing file in the output folder.
    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Input expansion

    /// Turn whatever was dropped — files, folders, nested folders — into a flat list of images.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles])
                while let child = e?.nextObject() as? URL {
                    if supportedExtensions.contains(child.pathExtension.lowercased()) {
                        out.append(child)
                    }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        // De-dupe while preserving drop order.
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardized.path).inserted }
    }
}
