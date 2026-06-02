import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let item: NSStatusItem
    private let store: StatusStore
    private weak var panelController: FloatingPanelController?
    private var cancellables: Set<AnyCancellable> = []
    private let port: UInt16

    init(store: StatusStore, panelController: FloatingPanelController, port: UInt16) {
        self.store = store
        self.panelController = panelController
        self.port = port
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureMenu()
        updateButton()

        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton(); self?.configureMenu() }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = item.button else { return }
        button.image = makeStatusImage(state: store.aggregateState)
        button.title = store.agents.isEmpty ? "" : " \(store.agents.count)"
        button.toolTip = "Agent Monitor — \(store.summary)"
    }

    private func configureMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Agent Monitor", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let summary = NSMenuItem(title: store.agents.isEmpty ? "No agents reported yet" : store.summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Floating Widget", action: #selector(showWidget), keyEquivalent: "s")
        show.target = self
        menu.addItem(show)

        let hide = NSMenuItem(title: "Hide Floating Widget", action: #selector(hideWidget), keyEquivalent: "h")
        hide.target = self
        menu.addItem(hide)

        let copyEndpoint = NSMenuItem(title: "Copy Local Endpoint", action: #selector(copyEndpoint), keyEquivalent: "c")
        copyEndpoint.target = self
        menu.addItem(copyEndpoint)

        menu.addItem(.separator())
        for agent in store.agents.prefix(8) {
            let item = NSMenuItem(title: "\(symbol(for: agent.state)) \(agent.name): \(agent.message.isEmpty ? agent.state.title : agent.message)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if store.agents.count > 8 {
            let more = NSMenuItem(title: "+ \(store.agents.count - 8) more…", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func showWidget() { panelController?.show() }
    @objc private func hideWidget() { panelController?.hide() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string)
    }

    private func symbol(for state: AgentState) -> String {
        switch state {
        case .green: "●"
        case .yellow: "●"
        case .red: "●"
        }
    }

    private func makeStatusImage(state: AgentState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let color: NSColor = switch state {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .red: .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
