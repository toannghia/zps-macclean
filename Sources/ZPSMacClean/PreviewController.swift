import AppKit
import Quartz

/// Mở Quick Look cho ảnh, video. Dùng thay `quickLookPreview` của SwiftUI: modifier đó mở bảng xem trước
/// giữa lúc giao diện đang vẽ và giữ cả danh sách hàng chục nghìn file đang thay đổi, gây crash.
@MainActor
final class PreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = PreviewController()

    /// Danh sách chụp lại lúc mở, không đổi theo bảng trong lúc đang quét.
    private var items: [URL] = []
    /// Số file hai bên file đang xem, để phím mũi tên vẫn duyệt được mà danh sách luôn nhỏ.
    private let neighbours = 100

    func show(_ url: URL, among all: [URL]) {
        let index = all.firstIndex(of: url)
        if let index {
            let range = max(0, index - neighbours) ..< min(all.count, index + neighbours + 1)
            items = Array(all[range])
        } else {
            items = [url]
        }
        let current = items.firstIndex(of: url) ?? 0
        // Chờ lượt vẽ hiện tại xong rồi mới mở, để Quick Look không chen vào giữa lúc SwiftUI cập nhật.
        DispatchQueue.main.async {
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.currentPreviewItemIndex = current
            if panel.isVisible {
                panel.refreshCurrentPreviewItem()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard items.indices.contains(index) else { return nil }
            return items[index] as NSURL
        }
    }
}
