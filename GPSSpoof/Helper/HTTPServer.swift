import Foundation
import Network

/// Minimal HTTP/1.1 server on NWListener: just enough for the helper's two
/// JSON endpoints. One short-lived connection per request (Connection: close).
final class HTTPServer {
    typealias Handler = (_ method: String, _ path: String, _ body: Data)
        -> (status: Int, json: [String: Any])

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "GPSSpoofHelper.http")

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "GPSSpoofHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.handler = handler
    }

    /// Starts listening; calls onReady with the actual bound port (resolves
    /// port 0 to the kernel-assigned ephemeral port — the tests rely on it).
    func start(onReady: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                onReady(self?.listener.port?.rawValue ?? 0)
            case .failed(let error):
                FileHandle.standardError.write(Data("listener failed: \(error)\n".utf8))
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] chunk, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffered
            if let chunk = chunk { buffer.append(chunk) }
            if let request = Self.parse(buffer) {
                let result = self.handler(request.method, request.path, request.body)
                self.respond(connection, status: result.status, json: result.json)
            } else if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel() // malformed, oversized, or closed early
            } else {
                self.receive(connection, buffered: buffer)
            }
        }
    }

    /// Returns nil while the request is still incomplete (keep buffering).
    private static func parse(_ data: Data)
        -> (method: String, path: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2,
               pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return (String(requestLine[0]), String(requestLine[1]),
                Data(body.prefix(contentLength)))
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        // sortedKeys gives deterministic bodies; the bash tests grep fragments.
        let body = (try? JSONSerialization.data(withJSONObject: json,
                                                options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden",
                       404: "Not Found", 409: "Conflict",
                       500: "Internal Server Error", 502: "Bad Gateway"]
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
