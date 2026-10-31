import SwiftUI

@main
struct ESP32CarControllerApp: App {
    @StateObject private var coordinator = ControlCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(coordinator)
                .onChange(of: scenePhase) { phase in
                    coordinator.setForeground(phase == .active)
                }
        }
    }
}
