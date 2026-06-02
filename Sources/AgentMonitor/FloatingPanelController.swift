import AppKit
import SwiftUI
import Combine

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let store: StatusStore
    private var panel: NSPanel?

    init(store: StatusStore) {
        self.store = store
        super.init()
    }

    func show() {
        if panel == nil { createPanel() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let content = MonitorWidgetView(store: store) { [weak self] in self?.hide() }
        let hosting = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 120, y: 760, width: 340, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        self.panel = panel
    }
}

struct MonitorWidgetView: View {
    @ObservedObject var store: StatusStore
    var onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(state: store.aggregateState, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Monitor")
                        .font(.headline)
                    Text(store.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.plain)
                .help("Hide. Bring back from menu bar.")
            }

            Divider().opacity(0.35)

            if store.agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No agents yet")
                        .font(.subheadline.bold())
                    Text("Agents can POST local updates to http://127.0.0.1:\(AppConfig.port)/agents/{id}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.agents) { agent in
                            AgentRow(agent: agent)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
        .padding(16)
        .frame(width: 340)
        .frame(minHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .contextMenu {
            Button("Hide Widget", action: onHide)
        }
        .background(WindowDragView())
    }
}

struct AgentRow: View {
    let agent: AgentRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: agent.state, size: 11)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent.name).font(.subheadline.bold())
                    Spacer()
                    Text(agent.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(agent.message.isEmpty ? agent.state.title : agent.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct StatusDot: View {
    let state: AgentState
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .shadow(color: state.color.opacity(0.7), radius: 4)
    }
}

struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ nsView: DragNSView, context: Context) {}
}

final class DragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
