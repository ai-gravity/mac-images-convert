import CoreGraphics
import Foundation
import ImageIO
import MacImagesConvertCore
import UniformTypeIdentifiers
import XCTest

final class ImageConversionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacImagesConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testJPEGConversionStripsGPSAndRespectsFormat() throws {
        let source = try makeImage(named: "camera.png", type: .png, gps: true)
        var options = ConversionOptions(); options.format = .jpeg; options.removeLocation = true
        let result = try ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options)
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(output.pathExtension, "jpg")
        let inspected = try ImageConverter.inspect(output)
        XCTAssertEqual(inspected.sourceType, UTType.jpeg.identifier)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        XCTAssertNil(metadata?[kCGImagePropertyGPSDictionary])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "conversion must not touch originals by default")
    }

    func testSizeCapDownsizesAndVerifiesActualBytes() throws {
        let source = try makeImage(named: "large.png", type: .png, width: 1600, height: 1000)
        var options = ConversionOptions(); options.format = .jpeg; options.jpegQuality = .maximum; options.sizeCap = SizeCap(bytes: 25_000, allowDownsizing: true)
        let result = try ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options)
        let output = try XCTUnwrap(result.output)
        XCTAssertLessThanOrEqual(try ImageConverter.inspect(output).byteCount, 25_000)
    }

    func testCapFailsWhenDownsizingIsDisabled() throws {
        let source = try makeImage(named: "uncapped.png", type: .png, width: 800, height: 600)
        var options = ConversionOptions(); options.format = .jpeg; options.sizeCap = SizeCap(bytes: 500, allowDownsizing: false)
        XCTAssertThrowsError(try ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options)) { error in
            XCTAssertEqual(error as? ConversionError, .cannotMeetSizeCap)
        }
    }

    func testAllEXIFOrientationsMatchPlatformRenderedPixels() throws {
        var options = ConversionOptions(); options.format = .png
        for orientation in 1...8 {
            let source = try makeImage(named: "orientation-\(orientation).jpg", type: .jpeg, width: 80, height: 40, orientation: orientation)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 80,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary))
            let output = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options).output)
            let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
            XCTAssertEqual(actual.width, expected.width, "orientation \(orientation) width")
            XCTAssertEqual(actual.height, expected.height, "orientation \(orientation) height")
            XCTAssertEqual(try rgbaBytes(actual), try rgbaBytes(expected), "orientation \(orientation) pixels")
        }
    }

    func testCollisionGeneratesSafeName() throws {
        let source = try makeImage(named: "same.png", type: .png)
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("same.jpg")
        try Data("do not overwrite".utf8).write(to: existing)
        var options = ConversionOptions(); options.format = .jpeg
        let result = try ImageConverter.convert(source, destination: destination, options: options)
        XCTAssertEqual(try XCTUnwrap(result.output).lastPathComponent, "same 1.jpg")
        XCTAssertEqual(try Data(contentsOf: existing), Data("do not overwrite".utf8))
    }

    func testMultiFrameInputIsRejected() throws {
        let source = try makeAnimatedGIF(named: "animated.gif")
        var options = ConversionOptions(); options.format = .png
        XCTAssertThrowsError(try ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options)) { error in
            guard case .multiFrame(let count) = error as? ConversionError else { return XCTFail("Expected multi-frame error") }
            XCTAssertEqual(count, 2)
        }
    }

    func testUnreadableFailureAndBatchOfFixtures() throws {
        let bad = root.appendingPathComponent("not-an-image.jpg"); try Data("plain text".utf8).write(to: bad)
        XCTAssertThrowsError(try ImageConverter.inspect(bad))
        let destination = root.appendingPathComponent("out")
        var options = ConversionOptions(); options.format = .png
        let inputs = try (0..<3).map { try makeImage(named: "batch-\($0).jpg", type: .jpeg) }
        let outputs = try inputs.map { try ImageConverter.convert($0, destination: destination, options: options).output }
        XCTAssertEqual(outputs.compactMap { $0 }.count, 3)
    }

    func testHEICConversionWhenAppleCodecIsAvailable() throws {
        let source = root.appendingPathComponent("iphone.heic")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw XCTSkip("This Mac has no HEIC encoder") }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("This Mac has no HEIC encoder") }
        var options = ConversionOptions(); options.format = .jpeg
        let output = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent("out"), options: options).output)
        XCTAssertEqual(try ImageConverter.inspect(output).sourceType, UTType.jpeg.identifier)
    }

    func testCustomBoundsKeepProportionsAndNeverEnlarge() throws {
        let source = try makeImage(named: "landscape.png", type: .png, width: 400, height: 300)
        var setup = ConversionSetup()
        setup.purpose = .resize; setup.resizePreset = "Custom"
        setup.width = "160"; setup.height = "100"
        let options = try setup.resolved(from: ConversionOptions())
        let output = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent("bounds"), options: options).output)
        let info = try ImageConverter.inspect(output)
        XCTAssertEqual(info.pixelWidth, 133); XCTAssertEqual(info.pixelHeight, 100)
        setup.width = "1600"; setup.height = "1000"
        let larger = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent("larger"), options: setup.resolved(from: ConversionOptions())).output)
        XCTAssertEqual(try ImageConverter.inspect(larger).pixelWidth, 400)
        XCTAssertEqual(try ImageConverter.inspect(larger).pixelHeight, 300)
    }

    func testPortraitBoundsAndActualUploadLimit() throws {
        let source = try makeImage(named: "portrait.png", type: .png, width: 600, height: 800)
        var setup = ConversionSetup(); setup.purpose = .resize; setup.resizePreset = "Custom"
        setup.width = "400"; setup.height = "400"
        let sized = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent("resize"), options: setup.resolved(from: ConversionOptions())).output)
        let info = try ImageConverter.inspect(sized)
        XCTAssertEqual(info.pixelWidth, 300); XCTAssertEqual(info.pixelHeight, 400)
        setup.purpose = .upload; setup.limitPreset = "Custom"; setup.limit = "10"; setup.unit = "KB"
        for format in OutputFormat.allCases {
            var base = ConversionOptions(); base.format = format
            let output = try XCTUnwrap(ImageConverter.convert(source, destination: root.appendingPathComponent(format.rawValue), options: setup.resolved(from: base)).output)
            let inspected = try ImageConverter.inspect(output)
            XCTAssertLessThanOrEqual(inspected.byteCount, 10_000)
            XCTAssertLessThanOrEqual(inspected.pixelWidth, 600)
            XCTAssertLessThanOrEqual(inspected.pixelHeight, 800)
        }
    }

    func testSwitchingPurposeIgnoresHiddenSettings() throws {
        var setup = ConversionSetup(); setup.purpose = .upload; setup.limitPreset = "Custom"
        setup.limit = "500"; setup.unit = "KB"; setup.resizePreset = "Custom"; setup.width = "bad"
        var base = ConversionOptions(); base.dimensions = .custom(width: 1, height: 1); base.sizeCap = SizeCap(bytes: 1)
        let upload = try setup.resolved(from: base)
        XCTAssertEqual(upload.dimensions, .original); XCTAssertEqual(upload.sizeCap?.bytes, 500_000)
        setup.purpose = .convert
        XCTAssertNil(try setup.resolved(from: base).sizeCap)
        XCTAssertEqual(try setup.resolved(from: base).dimensions, .original)
        setup.purpose = .resize; setup.width = "123"; setup.height = "456"
        XCTAssertEqual(try setup.resolved(from: base).dimensions, .custom(width: 123, height: 456))
        XCTAssertNil(try setup.resolved(from: base).sizeCap)
        setup.width = ""; XCTAssertThrowsError(try setup.resolved(from: base))
        setup.purpose = .upload; setup.limit = "nan"; XCTAssertThrowsError(try setup.resolved(from: base))
        setup.limit = "-2"; XCTAssertThrowsError(try setup.resolved(from: base))
    }

    private func makeImage(named name: String, type: UTType, width: Int = 320, height: Int = 200, gps: Bool = false, orientation: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A deterministic per-pixel pattern resists trivial compression and exercises cap handling.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(CGColor(red: CGFloat((x * 19 + y * 7) % 255) / 255, green: CGFloat((x * 3 + y * 29) % 255) / 255, blue: CGFloat((x * 11 + y * 5) % 255) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if gps { properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 13.7563, kCGImagePropertyGPSLongitude: 100.5018] }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeAnimatedGIF(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for index in 0..<2 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(index == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }

    private func rgbaBytes(_ image: CGImage) throws -> Data {
        let bytesPerRow = image.width * 4
        var bytes = Data(count: bytesPerRow * image.height)
        try bytes.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ConversionError.encodingFailed
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
