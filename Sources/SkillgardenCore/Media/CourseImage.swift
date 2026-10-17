import Foundation

/// A fixed-size raster copy of an image. The path is relative to the library root.
public struct ImageDerivative: Codable, Equatable, Sendable {
    public var path: String
    public var width: Int
    public var height: Int

    public init(path: String, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }
}

/// Store metadata for a published image. Paths are relative to the library root.
public struct CourseImage: Codable, Equatable, Sendable {
    public var path: String
    public var alt: String
    public var mimeType: String
    public var derivatives: [ImageDerivative]

    public init(path: String, alt: String, mimeType: String, derivatives: [ImageDerivative] = []) {
        self.path = path
        self.alt = alt
        self.mimeType = mimeType
        self.derivatives = derivatives.sorted { $0.width * $0.height < $1.width * $1.height }
    }

    /// The smallest derivative that covers the display size in pixels. SVG and large displays use the source.
    public func path(forPixelWidth width: Double, height: Double) -> String {
        derivatives.first { Double($0.width) >= width && Double($0.height) >= height }?.path ?? path
    }
}

/// The fixed derivative sizes for each manifest image field.
public enum ImageRole: Sendable {
    case course, sectionHeader

    public var sizes: [(width: Int, height: Int)] {
        switch self {
        case .course: [(750, 422), (375, 211)]
        case .sectionHeader: [(1920, 1080), (960, 540)]
        }
    }
}
