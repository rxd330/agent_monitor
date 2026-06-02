import Foundation
import SwiftUI

enum AgentState: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case red

    var title: String {
        switch self {
        case .green: "Finished"
        case .yellow: "Processing"
        case .red: "Needs human"
        }
    }

    var sortPriority: Int {
        switch self {
        case .red: 0
        case .yellow: 1
        case .green: 2
        }
    }

    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}

struct AgentRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var state: AgentState
    var message: String
    var updatedAt: Date
    var metadata: [String: String]

    init(id: String, name: String? = nil, state: AgentState, message: String = "", updatedAt: Date = Date(), metadata: [String: String] = [:]) {
        self.id = id
        self.name = name ?? id
        self.state = state
        self.message = message
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

struct AgentUpdateRequest: Codable, Sendable {
    var id: String?
    var name: String?
    var state: AgentState?
    var status: AgentState?
    var message: String?
    var metadata: [String: String]?
}

struct APIResponse<T: Encodable>: Encodable {
    var ok: Bool
    var data: T?
    var error: String?
}

struct EmptyPayload: Encodable {}
