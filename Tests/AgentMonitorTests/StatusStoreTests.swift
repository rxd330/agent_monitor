import XCTest
@testable import AgentMonitor

@MainActor
final class StatusStoreTests: XCTestCase {
    func testCountsAgentsByState() {
        let store = StatusStore()
        store.upsert(AgentRecord(id: "green-1", state: .green))
        store.upsert(AgentRecord(id: "yellow-1", state: .yellow))
        store.upsert(AgentRecord(id: "yellow-2", state: .yellow))
        store.upsert(AgentRecord(id: "red-1", state: .red))

        XCTAssertEqual(store.count(for: .green), 1)
        XCTAssertEqual(store.count(for: .yellow), 2)
        XCTAssertEqual(store.count(for: .red), 1)
        XCTAssertEqual(store.summary, "1 finished · 2 processing · 1 need human")
    }

    func testRemoveStaleAgentsUsesConfiguredMinuteThreshold() {
        let store = StatusStore()
        let now = Date(timeIntervalSince1970: 1_000)
        store.upsert(AgentRecord(id: "fresh", state: .green, updatedAt: now.addingTimeInterval(-60)))
        store.upsert(AgentRecord(id: "exact-cutoff", state: .yellow, updatedAt: now.addingTimeInterval(-300)))
        store.upsert(AgentRecord(id: "stale", state: .red, updatedAt: now.addingTimeInterval(-301)))

        let removed = store.removeStale(olderThanMinutes: 5, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.agents.map(\.id).sorted(), ["exact-cutoff", "fresh"])
    }
}
