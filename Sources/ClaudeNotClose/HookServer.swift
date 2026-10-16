import Foundation
import Network

/// Local HTTP endpoint that Claude Code hooks post to (127.0.0.1 only).
final class HookServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hook-server")

    static var secretPath: String { "/hook/" + Preferences.hookToken }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: UInt16(Preferences.hookPort)) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HookServer.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if error != nil || done || buffer.count > (4 << 20) {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        guard request.path == HookServer.secretPath else {
            send(status: "404 Not Found", body: "", on: connection)
            return
        }
        let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        Task {
            let body = await AgentBridge.handle(payload)
            self.send(status: "200 OK", body: body, on: connection)
        }
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bytes = body.data(using: .utf8) ?? Data()
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(bytes)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    struct Request {
        var method: String
        var path: String
        var body: Data
    }

    /// Returns a request once headers and the full body have arrived.
    static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), body: Data(body.prefix(length)))
    }
}
