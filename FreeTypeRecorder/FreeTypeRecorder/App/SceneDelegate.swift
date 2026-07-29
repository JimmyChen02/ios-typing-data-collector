import UIKit
import SwiftUI

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let touchWindow = TouchOverlayWindow(windowScene: windowScene)
        touchWindow.rootViewController = UIHostingController(rootView: ContentView())
        touchWindow.makeKeyAndVisible()
        window = touchWindow
    }
}
