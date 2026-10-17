import CoreGraphics
import Foundation
import PDFKit

/// The file type of a download. It picks the row symbol and the meta label.
public enum DownloadKind: Equatable, Sendable {
    case pdf, csv, zip
    /// Any other file. The value is the lowercase file extension, or empty if the file has none.
    case other(String)

    public init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": self = .pdf
        case "csv": self = .csv
        case "zip": self = .zip
        default: self = .other(ext)
        }
    }

    /// The SF Symbol of a row without a thumbnail.
    public var symbolName: String {
        switch self {
        case .pdf: "doc.richtext"
        case .csv: "tablecells"
        case .zip: "doc.zipper"
        case .other: "doc"
        }
    }

    /// The type in the meta line, for example "PDF". A file without an extension is "File".
    public var label: String {
        switch self {
        case .pdf: "PDF"
        case .csv: "CSV"
        case .zip: "ZIP"
        case .other(let ext): ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

/// One download of a lecture in the installed course snapshot, in manifest order.
public struct LectureDownload: Identifiable, Equatable, Sendable {
    /// The position in the `downloads` list. Two downloads can name the same file.
    public let id: Int
    public let title: String
    public let description: String?
    /// The file in the snapshot.
    public let url: URL
    public let kind: DownloadKind
    /// The file size at the last library reload. Nil if the snapshot has no file at `url`.
    public let byteCount: Int64?

    public init(id: Int, title: String, description: String?, url: URL, byteCount: Int64?) {
        self.id = id
        self.title = title
        self.description = description
        self.url = url
        kind = DownloadKind(path: url.path)
        self.byteCount = byteCount
    }

    /// Reads the file size from the snapshot. Returns nil if the path is outside the snapshot.
    public init?(id: Int, manifest: ManifestDownload, folder: URL) {
        guard let path = LectureArticle.normalize(manifest.path) else { return nil }
        let url = folder.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/") else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = values?.isRegularFile == true ? values?.fileSize.map(Int64.init) : nil
        let description = manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: id, title: manifest.title, description: description?.isEmpty == false ? description : nil,
                  url: url, byteCount: size)
    }

    /// The downloads of a lecture. Entries with a path outside the snapshot are left out.
    public static func list(_ downloads: [ManifestDownload]?, folder: URL) -> [LectureDownload] {
        (downloads ?? []).enumerated().compactMap { LectureDownload(id: $0.offset, manifest: $0.element, folder: folder) }
    }

    /// False if the snapshot file was missing at the last reload. The row dims and its buttons are disabled.
    public var isAvailable: Bool { byteCount != nil }

    /// The meta line, for example "PDF · 1.2 MB". A missing file shows the type only.
    public var meta: String {
        guard let byteCount else { return kind.label }
        return "\(kind.label) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }

    /// The name that the save panel suggests: `<title>.<ext>`. Path separators in the title become hyphens.
    public var suggestedFileName: String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        let ext = url.pathExtension
        guard !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) else { return name }
        return name + "." + ext
    }

    /// Writes the bytes of the file to `destination` and replaces a file that is there. The snapshot does not change.
    public func save(to destination: URL) throws {
        let data = try Data(contentsOf: url)
        try data.write(to: destination, options: .atomic)
    }
}

/// Reads PDF downloads with PDFKit. Call it off the main actor.
public enum PDFPreview {
    /// The number of pages, or nil if the file is not a readable PDF.
    public static func pageCount(of url: URL) -> Int? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        return document.pageCount
    }

    /// The footer text of the preview sheet, for example "Page 1 of 12".
    public static func pageLabel(page: Int, of count: Int) -> String {
        "Page \(page) of \(count)"
    }

    /// Draws page 1 on white so that it fits in `width` × `height` points at `scale`.
    /// Returns nil if the file is not a readable PDF.
    public static func firstPage(of url: URL, width: CGFloat, height: CGFloat, scale: CGFloat = 2) -> CGImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        // A rotated page draws with its width and height swapped.
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard pageSize.width > 0, pageSize.height > 0, width > 0, height > 0 else { return nil }
        let fit = min(width / pageSize.width, height / pageSize.height) * scale
        let pixelWidth = max(1, Int((pageSize.width * fit).rounded())), pixelHeight = max(1, Int((pageSize.height * fit).rounded()))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: CGFloat(pixelWidth) / pageSize.width, y: CGFloat(pixelHeight) / pageSize.height)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
