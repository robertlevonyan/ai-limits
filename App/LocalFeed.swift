import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that hands the latest snapshot to the widget.
///
/// Files in the App Group can be blocked or held by macOS's container protection (the widget then stays a
/// grey placeholder). A loopback request doesn't depend on signing or containers at all, so the widget asks
/// here first and only falls back to the shared files.
final class LocalFeed: @unchecked Sendable {
    static let shared = LocalFeed()

    private let queue = DispatchQueue(label: "AILimits.LocalFeed")
    private var listener: NWListener?
    private var body = Data("{}".utf8)

    func publish(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        queue.async { self.body = data }
    }

    func start() {
        queue.async { self.startListener() }
    }

    private func startListener() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: SharedStore.feedPort) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // Port busy (e.g. an older copy still running): try again shortly.
                self?.queue.asyncAfter(deadline: .now() + 10) {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.startListener()
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            guard let self else { connection.cancel(); return }
            let body = self.body
            var response = Data((
                "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n"
            ).utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
