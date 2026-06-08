import Foundation
import Network
import Darwin

final class LocalStatusServer: @unchecked Sendable {
    private let port: UInt16
    private let store: StatusStore
    private let queue = DispatchQueue(label: "agent-monitor.local-server")
    private var listener: NWListener?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(port: UInt16, store: StatusStore) {
        self.port = port
        self.store = store
    }

    static func isPortInUse(_ port: UInt16) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result != 0 && errno == EADDRINUSE
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection: connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("AgentMonitor server failed: \(String(describing: error))")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("AgentMonitor listening on http://127.0.0.1:\(port)")
        } catch {
            NSLog("AgentMonitor could not start local server on port \(port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }

            if let request = HTTPRequest.parse(next) {
                Task { await self.respond(to: request, on: connection) }
            } else if isComplete || error != nil {
                self.send(status: 400, body: ["ok": false, "error": "invalid HTTP request"], on: connection)
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    @MainActor
    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                send(status: 200, body: ["ok": true, "service": "agent-monitor", "port": port], on: connection)
            case ("GET", "/agents"):
                sendEncodable(status: 200, body: APIResponse(ok: true, data: store.agents, error: nil), on: connection)
            case ("DELETE", "/agents"):
                store.removeAll()
                sendEncodable(status: 200, body: APIResponse<EmptyPayload>(ok: true, data: EmptyPayload(), error: nil), on: connection)
            default:
                if request.method == "POST", let id = request.path.agentIDFromPath {
                    let update = try decoder.decode(AgentUpdateRequest.self, from: request.body)
                    let record = try store.update(id: id, request: update)
                    sendEncodable(status: 200, body: APIResponse(ok: true, data: record, error: nil), on: connection)
                } else if request.method == "DELETE", let id = request.path.agentIDFromPath {
                    let removed = store.remove(id: id)
                    send(status: removed ? 200 : 404, body: ["ok": removed], on: connection)
                } else {
                    send(status: 404, body: ["ok": false, "error": "not found"], on: connection)
                }
            }
        } catch {
            send(status: 400, body: ["ok": false, "error": error.localizedDescription], on: connection)
        }
    }

    private func sendEncodable<T: Encodable>(status: Int, body: T, on connection: NWConnection) {
        do {
            let data = try encoder.encode(body)
            sendRaw(status: status, json: data, on: connection)
        } catch {
            send(status: 500, body: ["ok": false, "error": "encoding failed"], on: connection)
        }
    }

    private func send(status: Int, body: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        sendRaw(status: status, json: data, on: connection)
    }

    private func sendRaw(status: Int, json: Data, on connection: NWConnection) {
        let reason = HTTPStatus.reason(status)
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(json.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(json)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        let rawPath = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? parts[1]
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        return HTTPRequest(method: parts[0].uppercased(), path: decodedPath, headers: headers, body: body)
    }
}

private extension String {
    var agentIDFromPath: String? {
        let prefix = "/agents/"
        guard hasPrefix(prefix) else { return nil }
        let rest = String(dropFirst(prefix.count))
        let id = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        return id.isEmpty ? nil : id
    }
}

enum HTTPStatus {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }
}
