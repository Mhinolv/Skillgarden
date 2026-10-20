// Render the editable course cover SVGs to PNG. Run from the repo root:
// swift scripts/render_course_covers.swift [output-directory]
import AppKit
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/course-covers")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for name in ["n8n-agents-course", "inside-the-checkpoint", "sample-course", "interactive-course"] {
    let source = URL(fileURLWithPath: "assets/CourseCovers/\(name).svg")
    guard let image = NSImage(contentsOf: source),
          let context = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot render \(source.path)")
    }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: 1600, height: 900))
    NSGraphicsContext.current = nil
    let url = output.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil),
          let raster = context.makeImage() else { fatalError("Cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, raster, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save \(url.path)") }
    print(url.path)
}
