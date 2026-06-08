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
    private let accountUsageStore = AccountUsageStore()
    private var statusBar: StatusBarController?
    private var panelController: FloatingPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var server: LocalStatusServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "staleAgentMinutes": 30.0,
            "floatingWidgetCompact": false,
        ])
        NSApp.setActivationPolicy(.accessory)

        let port = AppConfig.port
        if LocalStatusServer.isPortInUse(port) {
            showPortInUseWarning(port: port)
        } else {
            let server = LocalStatusServer(port: port, store: store)
            self.server = server
            server.start()
        }

        let panelController = FloatingPanelController(store: store)
        self.panelController = panelController

        let settingsWindowController = SettingsWindowController(usageStore: accountUsageStore)
        self.settingsWindowController = settingsWindowController

        let statusBar = StatusBarController(
            store: store,
            accountUsageStore: accountUsageStore,
            panelController: panelController,
            settingsWindowController: settingsWindowController,
            port: port
        )
        self.statusBar = statusBar

        accountUsageStore.startAutomaticRefresh()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func showPortInUseWarning(port: UInt16) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Agent Monitor port is already in use"
        alert.informativeText = "Port \(port) is already bound on 127.0.0.1, so this AgentMonitor instance cannot start its local status server. Quit the other process using the port, or relaunch AgentMonitor with AGENT_MONITOR_PORT set to a free port."
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
