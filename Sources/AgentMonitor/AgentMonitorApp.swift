import AppKit
import SwiftUI

@main
struct AgentMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep a placeholder Settings scene so SwiftUI's app lifecycle
        // initialises normally. User-facing configuration lives directly
        // in the menu-bar dropdown because this is a .accessory app.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var statusBar: StatusBarController?
    private var panelController: FloatingPanelController?
    private var server: LocalStatusServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "staleAgentMinutes": 30.0,
            "floatingWidgetCompact": false,
        ])
        NSApp.setActivationPolicy(.accessory)

        let port = AppConfig.port
        let server = LocalStatusServer(port: port, store: store)
        self.server = server
        server.start()

        let panelController = FloatingPanelController(store: store)
        self.panelController = panelController

        let statusBar = StatusBarController(store: store, panelController: panelController, port: port)
        self.statusBar = statusBar

        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
