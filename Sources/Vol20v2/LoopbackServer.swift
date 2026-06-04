//
// LoopbackServer.swift — tiny one-shot HTTP server for the OAuth redirect.
//
// The OAuth dance ends with the browser being redirected to
// `http://127.0.0.1:8888/callback?code=...`. The "server" on the other
// end of that URL is us. Our needs are extremely modest:
//   - Bind a TCP socket on 127.0.0.1:8888
//   - Accept ONE incoming GET
//   - Read the request line, extract the URL with its `?code=...`
//   - Send back a tiny "you can close this window" HTML page
//   - Shut down
//
// Built on Apple's Network.framework (NWListener / NWConnection) — modern,
// async-friendly, and doesn't require us to touch raw BSD sockets.
//
// The whole class is async-style: `awaitCallback()` is a single async
// function the caller awaits, and the listener tears itself down once the
// callback URL is returned.
//

import Foundation
import Network
import os

final class LoopbackServer {

    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "Loopback")

    enum LoopbackError: Error {
        case malformedRequest
        case listenerCancelled
    }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?

    init(port: UInt16) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw LoopbackError.malformedRequest
        }
        self.port = p
    }

    /// Starts the server and suspends until the first incoming HTTP GET
    /// arrives. Returns the full request URL (including `?code=...`).
    /// The server stops itself before returning.
    func awaitCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: port)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let err) = state {
                        Self.logger.error("Listener failed: \(err.localizedDescription)")
                        self?.complete(throwing: err)
                    }
                }
                listener.start(queue: .global())
                self.listener = listener
                Self.logger.notice("Loopback server listening on 127.0.0.1:\(self.port.rawValue, privacy: .public)")
            } catch {
                cont.resume(throwing: error)
                self.continuation = nil
            }
        }
    }

    // -------------------------------------------------------------------
    // handleConnection — one accepted connection from the browser.
    // We expect a single GET like:
    //   GET /callback?code=ABC123&state=XYZ HTTP/1.1
    //   Host: 127.0.0.1:8888
    //   ...
    // Read up to 4 KB, parse the request-line, and pull the path.
    // -------------------------------------------------------------------
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, _, error in

            guard let self else { return }
            if let error {
                self.complete(throwing: error)
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.complete(throwing: LoopbackError.malformedRequest)
                return
            }

            // Parse first line: "GET /callback?code=... HTTP/1.1"
            let firstLine = request
                .components(separatedBy: "\r\n")
                .first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendBadRequest(connection)
                self.complete(throwing: LoopbackError.malformedRequest)
                return
            }
            let path = String(parts[1])

            // Build a URL we can hand to URLComponents to extract query items.
            // The host doesn't matter for parsing — we only care about path+query.
            let fullURLString = "http://127.0.0.1:\(self.port.rawValue)\(path)"
            guard let url = URL(string: fullURLString) else {
                self.sendBadRequest(connection)
                self.complete(throwing: LoopbackError.malformedRequest)
                return
            }

            self.sendSuccessPage(connection)
            self.complete(with: url)
        }
    }

    private func sendSuccessPage(_ connection: NWConnection) {
        let body = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Vol20v2 authenticated</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; margin:0; background:#f6f7f8; color:#222; }
          .card { background:#fff; padding:32px 40px; border-radius:14px;
                  box-shadow:0 4px 24px rgba(0,0,0,0.08); text-align:center; }
          h1 { margin:0 0 8px; font-size:20px; }
          p  { margin:0; color:#666; font-size:14px; }
        </style></head>
        <body><div class="card">
          <h1>Vol20v2 is authenticated 🎛️</h1>
          <p>You can close this window and return to the menu bar.</p>
        </div></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendBadRequest(_ connection: NWConnection) {
        let response = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func complete(with url: URL) {
        listener?.cancel()
        listener = nil
        continuation?.resume(returning: url)
        continuation = nil
    }

    private func complete(throwing error: Error) {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
