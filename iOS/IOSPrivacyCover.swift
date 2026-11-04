import SwiftUI
import UIKit

/// Plain Yank cover shown in place of the app while a scene is not active. It is built from the
/// surface colour and the brand glyph only and is never given clip data.
struct IOSPrivacyCoverView: View {
    var body: some View {
        Color.yankSurface
            .ignoresSafeArea()
            .overlay {
                YankBrandGlyph(size: IOSMetric.emptyIconSize)
            }
    }
}

/// Keeps clip contents out of the app-switcher snapshot. Each window scene gets its own cover
/// window above every sheet, alert and activity controller; it is built while the scene is active,
/// shown the moment the scene is about to resign active, and hidden when the scene is active again.
@MainActor
final class IOSPrivacyCover {
    /// One level above alerts, so the cover also hides sheets, share sheets and dialogs.
    private static let coverWindowLevel = UIWindow.Level.alert + 1

    private var coverWindows: [String: UIWindow] = [:]
    private var observerTokens: [NSObjectProtocol] = []

    /// Registers nothing; call `startObserving()` to begin.
    init() {}

    // The cover is owned by the app delegate for the whole process, so the observers are never
    // removed and there is no `deinit` cleanup.
    func startObserving() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        // Delivered on the main queue during the scene transition, not a turn later, so the cover
        // is up before the system takes the snapshot.
        observerTokens = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.sceneWillDeactivate(scene) }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.sceneDidActivate(scene) }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.sceneDidDisconnect(scene) }
            },
        ]
    }

    private func sceneWillDeactivate(_ candidate: UIWindowScene?) {
        guard let scene = applicationScene(candidate) else { return }
        // The keyboard and its suggestion bar sit in system windows the cover cannot reach.
        scene.keyWindow?.endEditing(true)
        coverWindow(for: scene).isHidden = false
    }

    private func sceneDidActivate(_ candidate: UIWindowScene?) {
        guard let scene = applicationScene(candidate) else { return }
        coverWindow(for: scene).isHidden = true
    }

    private func sceneDidDisconnect(_ candidate: UIWindowScene?) {
        guard let scene = applicationScene(candidate) else { return }
        coverWindows.removeValue(forKey: scene.session.persistentIdentifier)?.isHidden = true
    }

    private func applicationScene(_ candidate: UIWindowScene?) -> UIWindowScene? {
        guard let scene = candidate, scene.session.role == .windowApplication else { return nil }
        return scene
    }

    private func coverWindow(for scene: UIWindowScene) -> UIWindow {
        let key = scene.session.persistentIdentifier
        if let existing = coverWindows[key] { return existing }

        let surface = UIColor(Color.yankSurface)
        let host = UIHostingController(rootView: IOSPrivacyCoverView())
        host.view.backgroundColor = surface

        let window = UIWindow(windowScene: scene)
        window.windowLevel = Self.coverWindowLevel
        window.backgroundColor = surface
        window.rootViewController = host
        window.isUserInteractionEnabled = false
        window.isAccessibilityElement = false
        window.accessibilityElementsHidden = true
        window.isHidden = true
        // Lay out now so the first frame shown is already the finished cover.
        host.view.layoutIfNeeded()

        coverWindows[key] = window
        return window
    }
}
