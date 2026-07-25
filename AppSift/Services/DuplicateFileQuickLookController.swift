import Foundation
import QuickLookUI

@MainActor
final class DuplicateFileQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var previewURLs: [URL] = []

    func present(_ item: DuplicateFileItem, in group: DuplicateFileGroup) {
        present(item.url, alongside: group.files.map(\.url))
    }

    func present(_ url: URL, alongside urls: [URL]) {
        let existingURLs = urls.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let selectedIndex = existingURLs.firstIndex(of: url),
              let panel = QLPreviewPanel.shared() else {
            return
        }
        previewURLs = existingURLs
        panel.dataSource = self
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
}
