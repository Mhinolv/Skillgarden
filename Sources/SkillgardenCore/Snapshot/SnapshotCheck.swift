import CoreGraphics
import Foundation
import ImageIO

/// Checks that the snapshot harness runs on a capture before it writes the PNG.
public enum SnapshotCheck {
    /// The highest red, green and blue value of a video pixel. The poster-less video frame is pure black.
    /// The darkest page and text colors of the Garden palettes are lighter.
    public static let blackLimit: UInt8 = 4

    /// The number of opaque black pixels in the top `height` pixel rows of `png` (#55).
    /// The rows are the title bar and the toolbar. A video that draws over the title bar adds black pixels.
    /// Nil when the data is not an image.
    public static func blackPixels(png: Data, topRows height: Int) -> Int? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, rows = min(max(height, 0), image.height)
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        // The first row in memory is the top row of the image.
        var count = 0
        for index in stride(from: 0, to: rows * width * 4, by: 4)
        where pixels[index + 3] == 255 && max(pixels[index], pixels[index + 1], pixels[index + 2]) <= blackLimit {
            count += 1
        }
        return count
    }
}
