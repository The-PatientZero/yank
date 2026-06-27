import Cocoa

extension HistoryContentView {
    /// Download all selected images to a folder
    func downloadAllImages() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.title = "Select Folder to Save Images"
        openPanel.prompt = "Select"

        if let window = NSApplication.shared.windows.first {
            openPanel.beginSheetModal(for: window) { response in
                guard response == .OK, let folderURL = openPanel.url else { return }
                // Blob-copy I/O is the store's job — it owns the blob layout. The
                // view just hands over the selected clips and the destination folder.
                do {
                    try store.exportImages(selectedItems, to: folderURL)
                } catch {
                    Log.app.error("Failed to export images: \(error.localizedDescription)")
                }
            }
        }
    }
}
