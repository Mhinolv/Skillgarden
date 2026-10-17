import Foundation
import ImageIO
import Testing

private let iconFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "assets/AppIcon")

/// The alpha values (0...255) of the four corner pixels of every image in the file.
/// Each entry is (pixel width, [top-left, top-right, bottom-left, bottom-right]).
private func cornerAlphas(of url: URL) throws -> [(width: Int, alphas: [UInt8])] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try (0..<CGImageSourceGetCount(source)).map { index in
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        return (width, corners.map { x, y in pixels[(y * width + x) * 4 + 3] })
    }
}

@Test func appIconPNGHasTransparentCorners() throws {
    let images = try cornerAlphas(of: iconFolder.appending(path: "AppIcon.png"))
    #expect(images.map(\.width) == [1024])
    #expect(images[0].alphas == [0, 0, 0, 0])
}

@Test func appIconICNSHasTransparentCornersAtEverySize() throws {
    let images = try cornerAlphas(of: iconFolder.appending(path: "AppIcon.icns"))
    #expect(images.contains { $0.width == 1024 })
    for image in images {
        #expect(image.alphas == [0, 0, 0, 0], "\(image.width) px image")
    }
}
