import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case jpeg = "JPG"
    case png = "PNG"
    public var id: String { rawValue }
    var uti: CFString { self == .jpeg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString }
    public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

public enum DimensionPreset: Sendable, Equatable {
    case original
    case percentage(Double)
    case longEdge(Int)
    case custom(width: Int, height: Int)

    public var label: String {
        switch self {
        case .original: "Original"
        case .percentage(let value): "\(Int(value * 100))%"
        case .longEdge(let value): "\(value)px long edge"
        case .custom(let width, let height): "\(width) × \(height)"
        }
    }
}

public enum JPEGQuality: String, CaseIterable, Sendable, Identifiable {
    case high = "High"
    case balanced = "Balanced"
    case maximum = "Maximum"
    public var id: String { rawValue }
    var value: Double { switch self { case .high: 0.86; case .balanced: 0.72; case .maximum: 0.96 } }
}

public struct SizeCap: Sendable, Equatable {
    public var bytes: Int
    public var allowDownsizing: Bool
    public init(bytes: Int, allowDownsizing: Bool = true) { self.bytes = bytes; self.allowDownsizing = allowDownsizing }
    public var label: String { bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(bytes / 1_000) KB" }
}

public struct ConversionOptions: Sendable {
    public var format: OutputFormat = .jpeg
    public var dimensions: DimensionPreset = .original
    public var jpegQuality: JPEGQuality = .high
    public var sizeCap: SizeCap?
    public var removeLocation: Bool = true
    public var moveOriginalToTrash: Bool = false
    public init() {}
}

public struct ImageInspection: Sendable, Equatable, Identifiable {
    public let url: URL
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let sourceType: String
    public var id: URL { url }
    public var dimensionsText: String { "\(pixelWidth) × \(pixelHeight) px" }
    public var bytesText: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

public enum ConversionError: LocalizedError, Sendable, Equatable {
    case unreadable(String)
    case unsupported(String)
    case multiFrame(Int)
    case invalidDimensions
    case cannotMeetSizeCap
    case encodingFailed
    case verificationFailed(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .unreadable(let value): "Cannot read \(value)."
        case .unsupported(let value): "\(value) is not a supported image format on this Mac."
        case .multiFrame(let count): "This image has \(count) frames. Animated or multi-page images are not converted."
        case .invalidDimensions: "The requested dimensions are invalid."
        case .cannotMeetSizeCap: "Could not meet the size cap with the selected format and settings."
        case .encodingFailed: "Image encoding failed."
        case .verificationFailed(let value): "Output verification failed: \(value)"
        case .cancelled: "Conversion was cancelled."
        }
    }
}

public struct ConversionResult: Sendable, Identifiable {
    public let source: URL
    public let output: URL?
    public let inspection: ImageInspection?
    public let error: ConversionError?
    public var id: URL { source }
    public var succeeded: Bool { output != nil && error == nil }
}

public enum ImageConverter {
    public static let acceptedExtensions = Set(["heic", "heif", "jpg", "jpeg", "png", "webp"])

    public static func inspect(_ url: URL) throws -> ImageInspection {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return ImageInspection(url: url, byteCount: values.fileSize ?? 0, pixelWidth: width, pixelHeight: height, frameCount: count, sourceType: type as String)
    }

    public static func decoderIsAvailable(for url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return false }
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(type as String)
    }

    public static func convert(_ sourceURL: URL, destination: URL, options: ConversionOptions, shouldCancel: @Sendable () -> Bool = { false }) throws -> ConversionResult {
        if shouldCancel() { throw ConversionError.cancelled }
        let inspection = try inspect(sourceURL)
        guard decoderIsAvailable(for: sourceURL) else { throw ConversionError.unsupported(sourceURL.lastPathComponent) }
        guard inspection.frameCount == 1 else { throw ConversionError.multiFrame(inspection.frameCount) }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.unreadable(sourceURL.lastPathComponent) }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let oriented = try orient(image, orientation: CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up)
        let target = try targetSize(for: oriented, preset: options.dimensions)
        var working = try resize(oriented, to: target)
        var data: Data?
        var finalSize = target
        for _ in 0..<20 {
            if shouldCancel() { throw ConversionError.cancelled }
            data = try encodedData(image: working, format: options.format, quality: options.jpegQuality.value, properties: sanitized(properties, removeLocation: options.removeLocation), cap: options.sizeCap?.bytes)
            if let cap = options.sizeCap, let data, data.count > cap.bytes {
                guard cap.allowDownsizing else { throw ConversionError.cannotMeetSizeCap }
                let scale = max(0.5, min(0.92, sqrt(Double(cap.bytes) / Double(data.count)) * 0.96))
                let next = CGSize(width: max(1, floor(finalSize.width * scale)), height: max(1, floor(finalSize.height * scale)))
                guard next.width < finalSize.width || next.height < finalSize.height else { throw ConversionError.cannotMeetSizeCap }
                finalSize = next
                working = try resize(oriented, to: finalSize)
                continue
            }
            break
        }
        guard let data else { throw ConversionError.encodingFailed }
        if let cap = options.sizeCap, data.count > cap.bytes { throw ConversionError.cannotMeetSizeCap }
        let output = try safeOutputURL(for: sourceURL, destination: destination, format: options.format)
        try writeAtomically(data, to: output)
        do { try verify(output, expectedFormat: options.format, maxBytes: options.sizeCap?.bytes, removeLocation: options.removeLocation) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        if options.moveOriginalToTrash && sourceURL.standardizedFileURL != output.standardizedFileURL {
            _ = try? FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
        }
        return ConversionResult(source: sourceURL, output: output, inspection: inspection, error: nil)
    }

    private static func targetSize(for image: CGImage, preset: DimensionPreset) throws -> CGSize {
        let original = CGSize(width: image.width, height: image.height)
        switch preset {
        case .original: return original
        case .percentage(let ratio): guard ratio > 0 else { throw ConversionError.invalidDimensions }; return CGSize(width: max(1, floor(original.width * ratio)), height: max(1, floor(original.height * ratio)))
        case .longEdge(let edge): guard edge > 0 else { throw ConversionError.invalidDimensions }; let ratio = min(1, CGFloat(edge) / max(original.width, original.height)); return CGSize(width: max(1, floor(original.width * ratio)), height: max(1, floor(original.height * ratio)))
        case .custom(let width, let height):
            guard width > 0, height > 0 else { throw ConversionError.invalidDimensions }
            let ratio = min(1, min(CGFloat(width) / original.width, CGFloat(height) / original.height))
            return CGSize(width: max(1, floor(original.width * ratio)), height: max(1, floor(original.height * ratio)))
        }
    }

    private static func resize(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionError.encodingFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw ConversionError.encodingFailed }
        return result
    }

    private static func orient(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        if orientation == .up { return image }
        let swaps = orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored
        let size = CGSize(width: swaps ? image.height : image.width, height: swaps ? image.width : image.height)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionError.encodingFailed }
        switch orientation {
        case .upMirrored: context.translateBy(x: size.width, y: 0); context.scaleBy(x: -1, y: 1)
        case .down: context.translateBy(x: size.width, y: size.height); context.rotate(by: .pi)
        case .downMirrored: context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        case .leftMirrored: context.translateBy(x: size.width, y: 0); context.rotate(by: .pi / 2); context.scaleBy(x: -1, y: 1)
        case .right: context.translateBy(x: size.width, y: 0); context.rotate(by: .pi / 2)
        case .rightMirrored: context.translateBy(x: size.width, y: size.height); context.rotate(by: .pi / 2); context.scaleBy(x: -1, y: 1)
        case .left: context.translateBy(x: 0, y: size.height); context.rotate(by: -.pi / 2)
        default: break
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ConversionError.encodingFailed }
        return result
    }

    private static func sanitized(_ source: [CFString: Any], removeLocation: Bool) -> [CFString: Any] {
        var result = source
        result[kCGImagePropertyOrientation] = 1
        if removeLocation {
            result.removeValue(forKey: kCGImagePropertyGPSDictionary)
            if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] { exif.removeValue(forKey: kCGImagePropertyExifUserComment); result[kCGImagePropertyExifDictionary] = exif }
            if var iptc = result[kCGImagePropertyIPTCDictionary] as? [CFString: Any] { ["City", "SubLocation", "ProvinceState", "CountryPrimaryLocationName", "CountryPrimaryLocationCode"].forEach { iptc.removeValue(forKey: $0 as CFString) }; result[kCGImagePropertyIPTCDictionary] = iptc }
        }
        return result
    }

    private static func encodedData(image: CGImage, format: OutputFormat, quality: Double, properties: [CFString: Any], cap: Int?) throws -> Data {
        var qualities: [Double] = format == .jpeg ? stride(from: quality, through: 0.20, by: -0.04).map { $0 } : [1]
        if qualities.isEmpty { qualities = [0.2] }
        var best: Data?
        for candidate in qualities {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, format.uti, 1, nil) else { throw ConversionError.encodingFailed }
            var options = properties
            if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = candidate }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
            let finished = data as Data
            best = finished
            if cap == nil || finished.count <= cap! { return finished }
        }
        return best ?? Data()
    }

    private static func safeOutputURL(for source: URL, destination: URL, format: OutputFormat) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        var index = 0
        while true {
            let suffix = index == 0 ? "" : " \(index)"
            let candidate = destination.appendingPathComponent(base + suffix).appendingPathExtension(format.fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func writeAtomically(_ data: Data, to output: URL) throws {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: output) }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private static func verify(_ output: URL, expectedFormat: OutputFormat, maxBytes: Int?, removeLocation: Bool) throws {
        let inspection = try inspect(output)
        guard (expectedFormat == .jpeg && inspection.sourceType == UTType.jpeg.identifier) || (expectedFormat == .png && inspection.sourceType == UTType.png.identifier) else { throw ConversionError.verificationFailed("wrong file format") }
        if let maxBytes, inspection.byteCount > maxBytes { throw ConversionError.verificationFailed("file is larger than the cap") }
        if removeLocation, let source = CGImageSourceCreateWithURL(output as CFURL, nil), let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], metadata[kCGImagePropertyGPSDictionary] != nil { throw ConversionError.verificationFailed("GPS metadata remains") }
    }
}
