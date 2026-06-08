import Darwin
import XCTest
@testable import AgentMonitor

final class LocalStatusServerTests: XCTestCase {
    func testIsPortInUseDetectsListeningLoopbackSocket() throws {
        let socketDescriptor = try makeListeningSocketOnLoopback()
        defer { close(socketDescriptor.descriptor) }

        XCTAssertTrue(LocalStatusServer.isPortInUse(socketDescriptor.port))
    }

    func testIsPortInUseReturnsFalseAfterSocketCloses() throws {
        let socketDescriptor = try makeListeningSocketOnLoopback()
        let port = socketDescriptor.port
        close(socketDescriptor.descriptor)

        XCTAssertFalse(LocalStatusServer.isPortInUse(port))
    }

    private func makeListeningSocketOnLoopback() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        XCTAssertEqual(listen(descriptor, 1), 0)

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)

        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }
}
