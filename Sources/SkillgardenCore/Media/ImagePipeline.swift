import CoreGraphics
import Foundation
import ImageIO

public enum ImageFormat: String, Equatable, Sendable {
    case png = "image/png", jpeg = "image/jpeg", svg = "image/svg+xml"
}

public enum ImagePipelineError: Error, Equatable, Sendable {
    case unsupportedFormat, unreadable

    /// Stable publish messages. The caller adds the file and field path.
    public var message: String {
        switch self {
        case .unsupportedFormat: "unsupported image format (use PNG, JPG or SVG)"
        case .unreadable: "the image cannot be read"
        }
    }
}

/// Validates PNG, JPG and SVG files and draws letterboxed raster derivatives.
public enum ImagePipeline {
    private static let rasterTypes: [String: ImageFormat] = ["public.png": .png, "public.jpeg": .jpeg]

    /// Raster formats come from the file content. SVG needs the .svg extension and an `svg` root element.
    public static func format(of url: URL) throws(ImagePipelineError) -> ImageFormat {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "svg" {
            guard isSVG(url) else { throw .unreadable }
            return .svg
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? {
            guard let format = rasterTypes[type] else { throw .unsupportedFormat }
            guard CGImageSourceGetCount(source) > 0, image(source) != nil else { throw .unreadable }
            return format
        }
        throw ["png", "jpg", "jpeg"].contains(pathExtension) ? .unreadable : .unsupportedFormat
    }

    /// Fits the full source in the target size. Transparent pixels fill the rest. The result is never cropped.
    public static func renderDerivative(from url: URL, width: Int, height: Int, to destination: URL) throws(ImagePipelineError) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = image(source),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .unreadable }
        let frame = fitRect(source: (image.width, image.height), target: (width, height))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: frame)
        guard let output = context.makeImage(),
              let file = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
            throw .unreadable
        }
        CGImageDestinationAddImage(file, output, nil)
        guard CGImageDestinationFinalize(file) else { throw .unreadable }
    }

    /// The centered aspect-fit rectangle in whole pixels.
    static func fitRect(source: (Int, Int), target: (Int, Int)) -> CGRect {
        let scale = min(Double(target.0) / Double(source.0), Double(target.1) / Double(source.1))
        let width = min(target.0, max(1, Int((Double(source.0) * scale).rounded())))
        let height = min(target.1, max(1, Int((Double(source.1) * scale).rounded())))
        return CGRect(x: (target.0 - width) / 2, y: (target.1 - height) / 2, width: width, height: height)
    }

    /// Applies the EXIF orientation so a rotated photo keeps its visible aspect.
    private static func image(_ source: CGImageSource) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func isSVG(_ url: URL) -> Bool {
        guard let parser = XMLParser(contentsOf: url) else { return false }
        let delegate = RootElement()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse() && delegate.name == "svg"
    }

    private final class RootElement: NSObject, XMLParserDelegate {
        var name: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == nil { name = elementName }
        }
    }
}
