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
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--keyboard-click-test") {
            touchWindow.rootViewController = UIHostingController(rootView: SimulatorKeyboardClickTestView())
        } else {
            touchWindow.rootViewController = UIHostingController(rootView: ContentView())
        }
        #else
        touchWindow.rootViewController = UIHostingController(rootView: ContentView())
        #endif
        touchWindow.makeKeyAndVisible()
        window = touchWindow
    }
}
