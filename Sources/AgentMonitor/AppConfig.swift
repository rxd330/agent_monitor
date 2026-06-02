import Foundation

enum AppConfig {
    static var port: UInt16 {
        if let raw = ProcessInfo.processInfo.environment["AGENT_MONITOR_PORT"], let value = UInt16(raw) {
            return value
        }
        return 8765
    }

    static let bindHost = "127.0.0.1"
}
