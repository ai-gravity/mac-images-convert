import Foundation

public enum ConversionPurpose: String, CaseIterable, Identifiable, Sendable {
    case convert = "Convert only"
    case resize = "Resize image"
    case upload = "Fit a file limit"
    public var id: String { rawValue }
}

/// Only the active purpose contributes settings. Hidden fields cannot affect a job.
public struct ConversionSetup: Sendable {
    public var purpose: ConversionPurpose = .convert
    public var resizePreset = "2048"
    public var width = "1600"
    public var height = "1200"
    public var limitPreset = "2 MB"
    public var limit = "2"
    public var unit = "MB"
    public init() {}

    public func resolved(from base: ConversionOptions) throws -> ConversionOptions {
        var result = base
        result.dimensions = .original
        result.sizeCap = nil
        switch purpose {
        case .convert: break
        case .resize:
            switch resizePreset {
            case "75%": result.dimensions = .percentage(0.75)
            case "50%": result.dimensions = .percentage(0.5)
            case "25%": result.dimensions = .percentage(0.25)
            case "Custom":
                guard let w = Int(width), let h = Int(height), (1...30000).contains(w), (1...30000).contains(h) else {
                    throw SetupError.invalidPixels
                }
                result.dimensions = .custom(width: w, height: h)
            default: result.dimensions = .longEdge(2048)
            }
        case .upload:
            result.jpegQuality = .high
            let bytes: Int
            switch limitPreset {
            case "500 KB": bytes = 500_000
            case "1 MB": bytes = 1_000_000
            case "2 MB": bytes = 2_000_000
            case "5 MB": bytes = 5_000_000
            default:
                guard let value = Double(limit), value.isFinite, value > 0 else { throw SetupError.invalidLimit }
                let total = value * (unit == "MB" ? 1_000_000 : 1_000)
                guard total >= 1_000, total <= 1_000_000_000 else { throw SetupError.invalidLimit }
                bytes = Int(total.rounded(.down))
            }
            result.sizeCap = SizeCap(bytes: bytes, allowDownsizing: true)
        }
        return result
    }
}

public enum SetupError: LocalizedError {
    case invalidPixels, invalidLimit
    public var errorDescription: String? {
        switch self {
        case .invalidPixels: "Enter a whole number from 1 to 30000 in both pixel fields."
        case .invalidLimit: "Enter a file limit between 1 KB and 1000 MB."
        }
    }
}
