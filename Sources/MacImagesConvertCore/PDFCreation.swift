import CoreGraphics
import Foundation
import ImageIO

public enum PDFPagePreset: String, CaseIterable, Identifiable, Sendable {
    case fitImage = "Fit each image"
    case a4 = "A4"
    case letter = "US Letter"

    public var id: String { rawValue }
}

public struct PDFOptions: Sendable {
    public var filename = "Combined images"
    public var pagePreset: PDFPagePreset = .fitImage
    public var margin: CGFloat = 24
    public init() {}
}

public enum PDFCreationError: LocalizedError, Sendable {
    case noImages
    case invalidFilename
    case unreadable(String)
    case multiFrame(String)
    case creationFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noImages: "Add at least one image."
        case .invalidFilename: "Enter a name for the PDF."
        case .unreadable(let name): "Cannot read \(name)."
        case .multiFrame(let name): "\(name) contains multiple frames and cannot be added to this PDF."
        case .creationFailed: "The PDF could not be created."
        case .cancelled: "PDF creation was cancelled."
        }
    }
}

public enum ImagePDFCreator {
    public static func create(
        from sourceURLs: [URL],
        destination: URL,
        options: PDFOptions,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> URL {
        guard !sourceURLs.isEmpty else { throw PDFCreationError.noImages }
        let cleanName = sanitizedFilename(options.filename)
        guard !cleanName.isEmpty else { throw PDFCreationError.invalidFilename }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let output = safeOutputURL(filename: cleanName, destination: destination)
        let temporary = destination.appendingPathComponent(".\(UUID().uuidString).pdf")
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(temporary as CFURL, mediaBox: &defaultBox, nil) else {
            throw PDFCreationError.creationFailed
        }

        do {
            for sourceURL in sourceURLs {
                if shouldCancel() { throw PDFCreationError.cancelled }
                let image = try decodedImage(from: sourceURL)
                let page = pageRect(for: image, preset: options.pagePreset)
                var mediaBox = page
                let mediaBoxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBoxData] as CFDictionary)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(page)
                context.interpolationQuality = .high
                context.draw(image, in: fittedRect(image: image, page: page, margin: options.pagePreset == .fitImage ? 0 : options.margin))
                context.endPDFPage()
            }
            context.closePDF()
            guard FileManager.default.fileExists(atPath: temporary.path) else { throw PDFCreationError.creationFailed }
            try FileManager.default.moveItem(at: temporary, to: output)
            return output
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func decodedImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw PDFCreationError.unreadable(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) == 1 else { throw PDFCreationError.multiFrame(url.lastPathComponent) }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw PDFCreationError.unreadable(url.lastPathComponent)
        }
        return image
    }

    private static func pageRect(for image: CGImage, preset: PDFPagePreset) -> CGRect {
        switch preset {
        case .fitImage:
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        case .a4:
            return orientedPage(width: 595, height: 842, image: image)
        case .letter:
            return orientedPage(width: 612, height: 792, image: image)
        }
    }

    private static func orientedPage(width: CGFloat, height: CGFloat, image: CGImage) -> CGRect {
        image.width > image.height
            ? CGRect(x: 0, y: 0, width: height, height: width)
            : CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func fittedRect(image: CGImage, page: CGRect, margin: CGFloat) -> CGRect {
        let available = page.insetBy(dx: margin, dy: margin)
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        var result = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(".pdf") { result.removeLast(4) }
        return result.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static func safeOutputURL(filename: String, destination: URL) -> URL {
        var index = 0
        while true {
            let suffix = index == 0 ? "" : " \(index)"
            let candidate = destination.appendingPathComponent(filename + suffix).appendingPathExtension("pdf")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
