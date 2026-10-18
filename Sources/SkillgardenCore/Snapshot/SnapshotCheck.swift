import CoreGraphics
import Foundation
import ImageIO

/// Checks that the snapshot harness runs on a capture before it writes the PNG.
public enum SnapshotCheck {
    /// The highest red, green and blue value of a video pixel. The poster-less video frame is pure black.
    /// The darkest page and text colors of the Garden palettes are lighter.
    public static let blackLimit: UInt8 = 4

    /// The widest black line in pixels that is not video: the split view divider in dark mode is 1 pt (2 pixels) wide (#82).
    public static let lineWidth = 2

    /// The number of opaque black pixels in the top `height` pixel rows of `png` (#55).
    /// The rows are the title bar and the toolbar. A video that draws over the title bar adds black pixels.
    /// Black runs of `lineWidth` pixels or fewer in a row are lines, such as the dark divider, so they do not count.
    /// Nil when the data is not an image.
    public static func blackPixels(png: Data, topRows height: Int) -> Int? {
        guard let (pixels, width, imageHeight) = rgbaPixels(png: png) else { return nil }
        let rows = min(max(height, 0), imageHeight)
        var count = 0
        for row in 0..<rows {
            var run = 0
            for column in 0...width {
                let index = (row * width + column) * 4
                if column < width, pixels[index + 3] == 255, max(pixels[index], pixels[index + 1], pixels[index + 2]) <= blackLimit {
                    run += 1
                } else {
                    if run > lineWidth { count += run }
                    run = 0
                }
            }
        }
        return count
    }

    /// The red, green and blue values of the pixel at `x`, `y` of `png`. The point `0, 0` is the top left pixel (#82).
    /// Nil when the data is not an image or the point is outside the image.
    public static func color(png: Data, x: Int, y: Int) -> [UInt8]? {
        guard let (pixels, width, height) = rgbaPixels(png: png), (0..<width).contains(x), (0..<height).contains(y) else {
            return nil
        }
        let index = (y * width + x) * 4
        return Array(pixels[index..<index + 3])
    }

    /// The RGBA bytes of `png` in device RGB. The first row in memory is the top row of the image.
    private static func rgbaPixels(png: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
