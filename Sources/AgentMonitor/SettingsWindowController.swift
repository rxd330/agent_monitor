import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let usageStore: AccountUsageStore

    init(usageStore: AccountUsageStore) {
        self.usageStore = usageStore
        let rootView = SettingsRootView(store: usageStore)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Agent Monitor Settings"
        window.setContentSize(NSSize(width: 680, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        usageStore.load()
    }
}

private struct SettingsRootView: View {
    @ObservedObject var store: AccountUsageStore
    @State private var selectedKind: AccountKind = .openAI

    var body: some View {
        NavigationSplitView {
            List(AccountKind.allCases, selection: $selectedKind) { kind in
                Label(kind.title, systemImage: iconName(for: kind))
                    .tag(kind)
            }
            .navigationTitle("Accounts")
            .frame(minWidth: 180)
        } detail: {
            AccountSettingsPane(kind: selectedKind, store: store)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func iconName(for kind: AccountKind) -> String {
        switch kind {
        case .openAI: "sparkles"
        case .codex: "terminal"
        case .deepSeek: "creditcard"
        }
    }
}

private struct AccountSettingsPane: View {
    let kind: AccountKind
    @ObservedObject var store: AccountUsageStore

    @State private var isEnabled = false
    @State private var apiKey = ""
    @State private var monthlyBudget = ""
    @State private var manualUsedAmount = ""
    @State private var tokenLimit = ""
    @State private var manualUsedTokens = ""

    var body: some View {
        let snapshot = store.snapshots[kind]

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title)
                            .font(.title2.bold())
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Show in dropdown", isOn: $isEnabled)
                        .toggleStyle(.switch)
                }

                GroupBox("Current Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot?.menuTitle ?? "Not configured")
                            .font(.headline)
                        Text(snapshot?.statusText ?? "Not configured")
                            .foregroundStyle(.secondary)
                        if let lastUpdated = snapshot?.lastUpdated {
                            Text("Last refreshed: \(lastUpdated.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                if kind != .codex {
                    GroupBox("Budget") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                Text("Monthly budget (USD)")
                                TextField("0.00", text: $monthlyBudget)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text(kind == .deepSeek ? "Manual used fallback (USD)" : "Used this month (USD)")
                                TextField("0.00", text: $manualUsedAmount)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }

                if kind == .codex {
                    GroupBox("Token Usage") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                Text("Monthly token limit")
                                TextField("0", text: $tokenLimit)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Used tokens")
                                TextField("0", text: $manualUsedTokens)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                } else {
                    GroupBox("API") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("API key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                            Text(apiHelpText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                    Button("Refresh Now") {
                        save()
                        Task { await store.refresh(kind) }
                    }
                    Spacer()
                    Button("Reload Saved Values") { loadFromStore() }
                }
            }
            .padding(24)
        }
        .onAppear { loadFromStore() }
        .onChange(of: kind) { _, _ in loadFromStore() }
    }

    private var description: String {
        switch kind {
        case .openAI:
            "Displays your configured OpenAI monthly API budget and usage in the menu-bar dropdown. OpenAI does not expose a simple remaining-budget endpoint for normal API keys, so this pane starts with reliable manual tracking."
        case .codex:
            "Displays Codex token limit, used tokens, and remaining tokens in the menu-bar dropdown."
        case .deepSeek:
            "Fetches live DeepSeek account balance when an API key is provided, with manual budget fallback fields for the dropdown."
        }
    }

    private var apiHelpText: String {
        switch kind {
        case .openAI:
            "API keys persist in an encrypted file in Application Support; the decrypt key is stored in macOS Keychain."
        case .deepSeek:
            "Used only to call https://api.deepseek.com/user/balance from this app. API keys persist in an encrypted file in Application Support; the decrypt key is stored in macOS Keychain."
        case .codex:
            ""
        }
    }

    private func loadFromStore() {
        let value = store.settings[kind] ?? .empty
        isEnabled = value.isEnabled
        apiKey = value.apiKey
        monthlyBudget = value.monthlyBudget > 0 ? String(format: "%.2f", value.monthlyBudget) : ""
        manualUsedAmount = value.manualUsedAmount > 0 ? String(format: "%.2f", value.manualUsedAmount) : ""
        tokenLimit = value.tokenLimit > 0 ? "\(value.tokenLimit)" : ""
        manualUsedTokens = value.manualUsedTokens > 0 ? "\(value.manualUsedTokens)" : ""
    }

    private func save() {
        let value = AccountSettings(
            isEnabled: isEnabled,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            monthlyBudget: Double(monthlyBudget) ?? 0,
            manualUsedAmount: Double(manualUsedAmount) ?? 0,
            tokenLimit: Int(tokenLimit) ?? 0,
            manualUsedTokens: Int(manualUsedTokens) ?? 0
        )
        store.update(kind, settings: value)
    }
}
