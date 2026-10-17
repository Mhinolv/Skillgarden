// Render an SVG to a PNG with a transparent background: swift scripts/render_icon.swift <svg> <pixels> <png> [shadow]
// sips fills the canvas with white and ignores the SVG drop-shadow filter. This script draws on a clear
// canvas. With "shadow", it adds the feDropShadow of AppIcon.svg (dy 14, stdDeviation 16, black 0.28 opacity).
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 4, let pixels = Int(arguments[2]),
      let svg = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("usage: render_icon.swift <svg> <pixels> <png> [shadow]\n".utf8))
    exit(1)
}
let scale = CGFloat(pixels) / 1024
let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
if arguments.count > 4, arguments[4] == "shadow" {
    // Core Graphics blur is about two times the SVG stdDeviation. The y axis points up.
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 32 * scale,
                      color: CGColor(gray: 0, alpha: 0.28))
}
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.current = nil
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: arguments[3]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
