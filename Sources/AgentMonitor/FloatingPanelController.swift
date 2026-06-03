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
    @AppStorage("staleAgentMinutes") private var staleAgentMinutes = 30.0
    @AppStorage("floatingWidgetCompact") private var isCompact = false
    var onHide: () -> Void

    var body: some View {
        Group {
            if isCompact {
                CompactTrafficLightView(store: store, onExpand: { isCompact = false }, onClose: onHide)
            } else {
                ExpandedMonitorView(
                    store: store,
                    staleAgentMinutes: staleAgentMinutes,
                    onMinimize: { isCompact = true },
                    onClose: onHide
                )
            }
        }
        .background(WindowDragView())
    }
}

struct ExpandedMonitorView: View {
    @ObservedObject var store: StatusStore
    let staleAgentMinutes: Double
    var onMinimize: () -> Void
    var onClose: () -> Void

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
                Button(action: { _ = store.removeStale(olderThanMinutes: staleAgentMinutes) }) {
                    Image(systemName: "trash.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear agents not reporting in the past \(Int(staleAgentMinutes)) minutes")

                Button(action: onMinimize) {
                    Image(systemName: "minus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Minimize to traffic-light counts")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close floating widget. Agents remain available from the menu bar.")
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
            Button("Minimize to Counts", action: onMinimize)
            Button("Close Floating Widget", action: onClose)
            Divider()
            Button("Clear Stale Agents (\(Int(staleAgentMinutes)) min)") {
                _ = store.removeStale(olderThanMinutes: staleAgentMinutes)
            }
        }
    }
}

struct CompactTrafficLightView: View {
    @ObservedObject var store: StatusStore
    var onExpand: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightCount(state: .red, count: store.count(for: .red))
            TrafficLightCount(state: .yellow, count: store.count(for: .yellow))
            TrafficLightCount(state: .green, count: store.count(for: .green))

            Divider()
                .frame(height: 22)
                .opacity(0.35)

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand floating widget")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close floating widget. Agents remain available from the menu bar.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .contextMenu {
            Button("Expand Widget", action: onExpand)
            Button("Close Floating Widget", action: onClose)
        }
    }
}

struct TrafficLightCount: View {
    let state: AgentState
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color)
                .frame(width: 26, height: 26)
                .shadow(color: state.color.opacity(0.6), radius: 4)
            Text("\(count)")
                .font(.caption2.bold())
                .monospacedDigit()
                .foregroundStyle(.black.opacity(0.78))
                .minimumScaleFactor(0.6)
        }
        .accessibilityLabel("\(count) \(state.title.lowercased()) agents")
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
                    Button {
                        TerminalLauncher.openTerminal(for: agent)
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.plain)
                    .help("Open this agent's terminal")

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
