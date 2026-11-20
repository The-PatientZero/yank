import Foundation
import Testing
@testable import Yank

@Suite("App termination")
@MainActor
struct AppDelegateTerminationTests {
    @Test("Terminating with a pending delete commits it instead of resurrecting the item")
    func terminateCommitsPendingDelete() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankTerminationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let item = ClipboardItem(type: .text, textContent: "pending delete")
        store.add(item)
        store.delete(item)
        #expect(store.pendingDeletion != nil)

        AppDelegate.terminate(store: store, controller: nil)

        #expect(store.pendingDeletion == nil)
        #expect(store.items.isEmpty)
        #expect(store.tombstones[item.id] != nil)
    }

    @Test("Terminating with nothing pending is a no-op on the history")
    func terminateWithoutPendingDeleteLeavesHistoryUntouched() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankTerminationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let item = ClipboardItem(type: .text, textContent: "kept")
        store.add(item)

        AppDelegate.terminate(store: store, controller: nil)

        #expect(store.pendingDeletion == nil)
        #expect(store.items.map(\.id) == [item.id])
        #expect(store.tombstones.isEmpty)
    }
}
