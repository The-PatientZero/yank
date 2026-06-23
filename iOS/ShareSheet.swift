import SwiftUI
import UIKit

/// Presents the system share sheet for a batch of clips (text strings and/or images) —
/// the iOS analog of the Mac's "download all images", but routed through the share
/// sheet so the user can save, copy, or send anywhere.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
