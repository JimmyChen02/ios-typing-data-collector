import UIKit

// UIKit app delegate is required (instead of the plain SwiftUI @main App
// struct) so we can hand UIKit a custom UIWindow subclass (TouchOverlayWindow)
// via SceneDelegate — SwiftUI's own App/WindowGroup APIs don't expose the
// window itself, and we need to intercept touches at the window level to
// draw tap ripples on top of everything for the screen recording.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
