import Foundation

struct ClipboardBlobReference: Hashable, Sendable {
    enum Kind: String, Sendable {
        case image
        case text
        case rich
    }

    let kind: Kind
    let filename: String
}

enum ClipboardBlobCleanup {
    static func references(in item: ClipboardItem) -> [ClipboardBlobReference] {
        var references: [ClipboardBlobReference] = []
        append(.image, item.imageFilename, to: &references)
        append(.text, item.textFilename, to: &references)
        append(.rich, item.richFilename, to: &references)
        return references
    }

    static func referencesToDelete(
        removing removedItems: [ClipboardItem],
        keeping keptItems: [ClipboardItem] = []
    ) -> [ClipboardBlobReference] {
        let removed = uniqueReferences(in: removedItems)
        let kept = uniqueReferences(in: keptItems)
        return sorted(removed.subtracting(kept))
    }

    static func referencesRemoved(
        from previousItems: [ClipboardItem],
        keeping nextItems: [ClipboardItem]
    ) -> [ClipboardBlobReference] {
        referencesToDelete(removing: previousItems, keeping: nextItems)
    }

    private static func append(
        _ kind: ClipboardBlobReference.Kind,
        _ filename: String?,
        to references: inout [ClipboardBlobReference]
    ) {
        guard let filename = canonicalFilename(filename, kind: kind) else { return }
        references.append(ClipboardBlobReference(kind: kind, filename: filename))
    }

    private static func canonicalFilename(
        _ filename: String?,
        kind: ClipboardBlobReference.Kind
    ) -> String? {
        switch kind {
        case .image:
            SyncBlobPolicy.canonicalImageFilename(filename)
        case .text:
            SyncBlobPolicy.canonicalTextFilename(filename)
        case .rich:
            SyncBlobPolicy.canonicalRichFilename(filename)
        }
    }

    private static func uniqueReferences(in items: [ClipboardItem]) -> Set<ClipboardBlobReference> {
        Set(items.flatMap(references(in:)))
    }

    private static func sorted(_ references: Set<ClipboardBlobReference>) -> [ClipboardBlobReference] {
        references.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.filename < $1.filename
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}
