import Foundation
import Combine

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var agents: [AgentRecord] = []

    var aggregateState: AgentState {
        if agents.contains(where: { $0.state == .red }) { return .red }
        if agents.contains(where: { $0.state == .yellow }) { return .yellow }
        return .green
    }

    var summary: String {
        let red = agents.filter { $0.state == .red }.count
        let yellow = agents.filter { $0.state == .yellow }.count
        let green = agents.filter { $0.state == .green }.count
        return "\(green) finished · \(yellow) processing · \(red) need human"
    }

    func upsert(_ record: AgentRecord) {
        if let index = agents.firstIndex(where: { $0.id == record.id }) {
            agents[index] = record
        } else {
            agents.append(record)
        }
        sortAgents()
    }

    func update(id: String, request: AgentUpdateRequest) throws -> AgentRecord {
        let newState = request.state ?? request.status
        guard let state = newState else {
            throw StatusStoreError.missingState
        }

        let existing = agents.first(where: { $0.id == id })
        let mergedMetadata = (existing?.metadata ?? [:]).merging(request.metadata ?? [:]) { _, new in new }
        let record = AgentRecord(
            id: id,
            name: request.name ?? existing?.name ?? id,
            state: state,
            message: request.message ?? existing?.message ?? "",
            updatedAt: Date(),
            metadata: mergedMetadata
        )
        upsert(record)
        return record
    }

    func remove(id: String) -> Bool {
        let before = agents.count
        agents.removeAll { $0.id == id }
        return agents.count != before
    }

    func removeAll() {
        agents.removeAll()
    }

    private func sortAgents() {
        agents.sort { left, right in
            if left.state.sortPriority != right.state.sortPriority {
                return left.state.sortPriority < right.state.sortPriority
            }
            return left.updatedAt > right.updatedAt
        }
    }
}

enum StatusStoreError: Error, LocalizedError {
    case missingState

    var errorDescription: String? {
        switch self {
        case .missingState: "JSON must include state or status: green, yellow, or red"
        }
    }
}
