import Cocoa
import UniformTypeIdentifiers

extension HistoryContentView {
    func dragProvider(for item: ClipboardItem) -> NSItemProvider {
        if item.type == .image, let url = store.blobURL(for: item) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        if case let .link(url) = item.kind {
            return NSItemProvider(object: url as NSURL)
        }
        if item.textFilename != nil, let url = store.blobURL(for: item) {
            return fileBackedTextProvider(for: item, url: url)
        }
        let text = store.fullText(for: item) ?? item.excerpt
        return NSItemProvider(object: text as NSString)
    }

    private func fileBackedTextProvider(for item: ClipboardItem, url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.sourceApp.map { "Yank clip from \($0)" } ?? "Yank clip"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: "public.utf8-plain-text",
            visibility: .all
        ) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    completion(try Data(contentsOf: url), nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }
}
