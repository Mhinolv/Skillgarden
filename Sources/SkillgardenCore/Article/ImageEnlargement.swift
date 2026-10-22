import CoreGraphics

/// The size limit of an enlarged article image (#238). A bitmap never draws past its pixel size.
public enum ImageEnlargement {
    /// The largest size in points for an image with `pixelSize` on a display with `displayScale`.
    /// Nil means no limit: a vector image (SVG, PDF) has no pixel size, so it fills the space.
    public static func maximumSize(pixelSize: CGSize?, displayScale: CGFloat) -> CGSize? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let scale = displayScale > 0 ? displayScale : 1
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }
}
