import AppKit
import PDFKit
import SwiftUI
import SkillgardenCore

/// The "Downloads" block of a lecture page: one row per download in manifest order. Hidden when the lecture has none.
struct DownloadsBlock: View {
    let downloads: [LectureDownload]
    @State private var previewing: LectureDownload?

    var body: some View {
        if !downloads.isEmpty {
            VStack(alignment: .leading, spacing: GardenSpacing.xs) {
                Label("Downloads", systemImage: "arrow.down.doc")
                    .gardenText(.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                GardenCard {
                    VStack(alignment: .leading, spacing: GardenSpacing.s) {
                        ForEach(downloads) { download in
                            if download.id != downloads.first?.id { Divider() }
                            DownloadRow(download: download) { previewing = download }
                        }
                    }
                }
                .padding(.top, GardenSpacing.xxs)
            }
            .sheet(item: $previewing) { PDFPreviewSheet(download: $0) }
        }
    }
}

/// One download: the first-page thumbnail or a type symbol, the title, description and meta line, then the buttons.
struct DownloadRow: View {
    let download: LectureDownload
    let preview: () -> Void
    @Environment(\.gardenPalette) private var palette

    private var isPDF: Bool { download.kind == .pdf }

    var body: some View {
        HStack(alignment: .center, spacing: GardenSpacing.s) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(download.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = download.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
                Text(download.meta)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                if !download.isAvailable {
                    Text("File unavailable").font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: GardenSpacing.xs) {
                if isPDF {
                    Button("Preview", action: preview)
                        .accessibilityLabel("Preview \(download.title)")
                }
                Button("Save…") { DownloadSaver.save(download) }
                    .accessibilityLabel("Save \(download.title)")
            }
            .buttonStyle(.garden(.soft, .small))
            .disabled(!download.isAvailable)
        }
        .opacity(download.isAvailable ? 1 : 0.6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var leading: some View {
        if isPDF, download.isAvailable {
            Button(action: preview) { PDFThumbnail(url: download.url) }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview of \(download.title)")
        } else {
            Image(systemName: download.kind.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(palette.muted)
                .frame(width: DownloadStyle.thumbnail.width, height: DownloadStyle.thumbnail.height)
                .accessibilityHidden(true)
        }
    }
}

enum DownloadStyle {
    static let thumbnail = CGSize(width: 64, height: 83)
    static let sheet = CGSize(width: 560, height: 720)
}

/// Page 1 of a PDF at 64 × 83 pt with a 1 pt separator border. The page renders off the main actor.
struct PDFThumbnail: View {
    let url: URL
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.gardenPalette) private var palette
    @State private var image: NSImage?

    var body: some View {
        let size = DownloadStyle.thumbnail
        ZStack {
            Rectangle().fill(palette.soft)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: DownloadKind.pdf.symbolName).font(.system(size: 28)).foregroundStyle(palette.muted)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay { Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        .task(id: url) {
            image = nil
            imageLoads?.start()
            let rendered = await Task.detached {
                PDFPreview.firstPage(of: url, width: size.width, height: size.height)
            }.value
            image = rendered.map { NSImage(cgImage: $0, size: .zero) }
            imageLoads?.finish(loaded: rendered != nil)
        }
    }
}

/// The PDF preview sheet: page 1 in a PDFKit view, then the page count, "Open in Preview", "Save…" and "Done".
struct PDFPreviewSheet: View {
    let download: LectureDownload
    @Environment(\.dismiss) private var dismiss
    @State private var pageCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            PDFKitView(url: download.url)
            Divider()
            HStack(spacing: GardenSpacing.xs) {
                Text(pageCount.map { PDFPreview.pageLabel(page: 1, of: $0) } ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                // The owner decision names the button "Open in Preview". It opens the default app for PDFs.
                Button("Open in Preview") { NSWorkspace.shared.open(download.url) }
                Button("Save…") { DownloadSaver.save(download) }
                    .accessibilityLabel("Save \(download.title)")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(GardenSpacing.s)
        }
        .frame(width: DownloadStyle.sheet.width, height: DownloadStyle.sheet.height)
        .onExitCommand { dismiss() }
        .task(id: download.url) {
            let url = download.url
            pageCount = await Task.detached { PDFPreview.pageCount(of: url) }.value
        }
    }
}

/// A PDFKit view that shows one page at a time and scales it to fit.
private struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// The save flow: a save panel with `<title>.<ext>`, then a write of the file bytes. A cancel does nothing.
@MainActor
enum DownloadSaver {
    static func save(_ download: LectureDownload) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = download.suggestedFileName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            Task {
                // Read and write the file off the main actor.
                let failure = await Task.detached { () -> String? in
                    do { try download.save(to: target); return nil } catch { return error.localizedDescription }
                }.value
                guard let failure else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not save the file."
                alert.informativeText = failure
                alert.runModal()
            }
        }
    }
}

struct DownloadsBlock_Previews: PreviewProvider {
    static var previews: some View {
        let folder = URL(fileURLWithPath: "/tmp/skillgarden-preview")
        DownloadsBlock(downloads: [
            LectureDownload(id: 0, title: "Course plan worksheet", description: "Fill in one row for each section.",
                            url: folder.appending(path: "worksheet.pdf"), byteCount: 1_200_000),
            LectureDownload(id: 1, title: "Section list", description: nil, url: folder.appending(path: "sections.csv"),
                            byteCount: 46),
            LectureDownload(id: 2, title: "Plan checklist", description: nil, url: folder.appending(path: "checklist.txt"),
                            byteCount: nil),
        ])
        .padding()
        .frame(width: 720)
    }
}
