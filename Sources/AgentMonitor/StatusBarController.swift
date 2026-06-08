import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let item: NSStatusItem
    private let store: StatusStore
    private let accountUsageStore: AccountUsageStore
    private weak var panelController: FloatingPanelController?
    private weak var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private let port: UInt16
    private let staleThresholdOptions: [Double] = [5, 15, 30, 60, 120, 240]

    init(
        store: StatusStore,
        accountUsageStore: AccountUsageStore,
        panelController: FloatingPanelController,
        settingsWindowController: SettingsWindowController,
        port: UInt16
    ) {
        self.store = store
        self.accountUsageStore = accountUsageStore
        self.panelController = panelController
        self.settingsWindowController = settingsWindowController
        self.port = port
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureMenu()
        updateButton()

        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton(); self?.configureMenu() }
            .store(in: &cancellables)
    }

    private var staleAgentMinutes: Double {
        let configured = UserDefaults.standard.double(forKey: "staleAgentMinutes")
        return configured > 0 ? configured : 30
    }

    private var startsCompact: Bool {
        UserDefaults.standard.bool(forKey: "floatingWidgetCompact")
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

        let close = NSMenuItem(title: "Close Floating Widget", action: #selector(hideWidget), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)

        let clearStale = NSMenuItem(title: "Clear Stale Agents (\(Int(staleAgentMinutes)) min)", action: #selector(clearStaleAgents), keyEquivalent: "")
        clearStale.target = self
        clearStale.isEnabled = !store.agents.isEmpty
        menu.addItem(clearStale)

        menu.addItem(.separator())
        addAccountUsageItems(to: menu)
        menu.addItem(.separator())

        let settings = makeSettingsMenuItem()
        menu.addItem(settings)

        let copyEndpoint = NSMenuItem(title: "Copy Local Endpoint", action: #selector(copyEndpoint), keyEquivalent: "c")
        copyEndpoint.target = self
        menu.addItem(copyEndpoint)

        menu.addItem(.separator())
        for agent in store.agents.prefix(12) {
            let item = NSMenuItem(title: "\(symbol(for: agent.state)) \(agent.name): \(agent.message.isEmpty ? agent.state.title : agent.message)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if store.agents.count > 12 {
            let more = NSMenuItem(title: "+ \(store.agents.count - 12) more…", action: nil, keyEquivalent: "")
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

    @objc private func showSettingsWindow() {
        settingsWindowController?.show()
    }

    @objc private func clearStaleAgents() {
        _ = store.removeStale(olderThanMinutes: staleAgentMinutes)
        configureMenu()
        updateButton()
    }

    @objc private func toggleCompactMode(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!startsCompact, forKey: "floatingWidgetCompact")
        configureMenu()
    }

    @objc private func setStaleThreshold(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        UserDefaults.standard.set(Double(sender.tag), forKey: "staleAgentMinutes")
        configureMenu()
    }

    private func makeSettingsMenuItem() -> NSMenuItem {
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let openSettings = NSMenuItem(title: "Open Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        openSettings.target = self
        submenu.addItem(openSettings)
        submenu.addItem(.separator())

        let compact = NSMenuItem(title: "Start Floating Widget Compact", action: #selector(toggleCompactMode(_:)), keyEquivalent: "")
        compact.target = self
        compact.state = startsCompact ? .on : .off
        submenu.addItem(compact)

        submenu.addItem(.separator())

        let thresholdHeader = NSMenuItem(title: "Stale Agent Threshold", action: nil, keyEquivalent: "")
        thresholdHeader.isEnabled = false
        submenu.addItem(thresholdHeader)

        for minutes in staleThresholdOptions {
            let item = NSMenuItem(title: "\(Int(minutes)) minutes", action: #selector(setStaleThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(minutes)
            item.state = Int(staleAgentMinutes) == Int(minutes) ? .on : .off
            submenu.addItem(item)
        }

        settings.submenu = submenu
        return settings
    }

    private func addAccountUsageItems(to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = AccountUsageMenuView(store: accountUsageStore)
        menu.addItem(item)
    }

    @objc private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string)
    }

    private func symbol(for state: AgentState) -> String {
        switch state {
        case .green: "🟢"
        case .yellow: "🟡"
        case .red: "🔴"
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

@MainActor
private final class AccountUsageMenuView: NSView {
    private let store: AccountUsageStore
    private let stack = NSStackView()
    private var cancellables: Set<AnyCancellable> = []

    init(store: AccountUsageStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        setup()
        updateContent()

        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &cancellables)

        store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateContent() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let snapshots = enabledSnapshots
        stack.addArrangedSubview(label(
            snapshots.isEmpty ? "Account Usage: not configured" : "Account Usage",
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: snapshots.isEmpty ? .secondaryLabelColor : .labelColor
        ))

        for snapshot in snapshots {
            stack.addArrangedSubview(accountBlock(for: snapshot))
        }

        let refresh = NSButton(title: "↻ Refresh Account Usage", target: self, action: #selector(refreshAccountUsage))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.isEnabled = !snapshots.isEmpty
        refresh.toolTip = "Refreshes account usage without closing this dropdown"
        stack.addArrangedSubview(refresh)

        let height = max(44, stack.fittingSize.height)
        frame = NSRect(x: 0, y: 0, width: 360, height: height)
        invalidateIntrinsicContentSize()
    }

    private var enabledSnapshots: [AccountSnapshot] {
        AccountKind.allCases.compactMap { kind in
            guard store.settings[kind]?.isEnabled == true else { return nil }
            return store.snapshots[kind]
        }
    }

    private func accountBlock(for snapshot: AccountSnapshot) -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 2
        block.addArrangedSubview(label(snapshot.menuTitle, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor))
        if let detailText = snapshot.detailText {
            block.addArrangedSubview(label(detailText, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }
        return block
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 324
        return field
    }

    @objc private func refreshAccountUsage() {
        store.refreshAll()
        updateContent()
    }
}
