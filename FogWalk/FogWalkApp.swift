import SwiftUI

@MainActor
enum AppRuntime {
    static let model = AppModel()
    static var isUnitTestHost: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["FOGWALK_UNIT_TEST_HOST"] == "1"
        #else
        false
        #endif
    }

    static func keepScreenAwake(_ active: Bool) {
        guard !isUnitTestHost else { return }
        UIApplication.shared.isIdleTimerDisabled = active
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if AppRuntime.isUnitTestHost { return true }
        // Re-establish only a previously user-enabled recording session.
        let launchedForLocationEvent = launchOptions?[.location] != nil
        AppRuntime.model.locationManager.setBackground(application.applicationState == .background)
        AppRuntime.model.locationManager.restoreRecordingIfNeeded(launchedForLocationEvent: launchedForLocationEvent)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !AppRuntime.isUnitTestHost else { return }
        AppRuntime.keepScreenAwake(true)
        AppRuntime.model.applicationBecameActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        guard !AppRuntime.isUnitTestHost else { return }
        AppRuntime.keepScreenAwake(false)
        AppRuntime.model.locationManager.setBackground(true)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppRuntime.keepScreenAwake(false)
    }
}

@main
struct FogWalkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            if AppRuntime.isUnitTestHost {
                // Individual interaction tests host their own map. Do not start
                // a second map, GPS, permission prompts, or archive restoration.
                Color.clear
            } else {
                ContentView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        AppRuntime.keepScreenAwake(true)
                        AppRuntime.model.applicationBecameActive()
                    } else if phase == .background {
                        AppRuntime.keepScreenAwake(false)
                        AppRuntime.model.locationManager.setBackground(true)
                    }
                }
            }
        }
    }
}
