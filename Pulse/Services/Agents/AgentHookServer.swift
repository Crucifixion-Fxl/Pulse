// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIsland/HookServer.swift, transport half)
//
// The Unix-domain-socket transport: accept a bridge connection, read one JSON
// hook payload until the client half-closes, route it through
// AgentSessionStore (which may block on the user), write the response, close.
// Not ported from upstream: Cursor/Codex sub-session pre-routing, webhook
// forwarding, remote-host cwd filters, settings-driven auto-approve sources,
// diagnostics ring buffer — the store keeps the routing decisions.
//
// NWConnection / NWListener are not Sendable in the SDK's swiftinterface, but
// the framework is designed for cross-queue use; captures that hand one into
// a Task use `nonisolated(unsafe)` to say so at each site.

import Foundation
import Network
import Darwin

@MainActor
final class AgentHookServer {

    private let store: AgentSessionStore
    private let socketPathValue: String
    private var listener: NWListener?

    /// The socket every bridge connects to (env-overridable, see AgentSocketPath).
    var socketPath: String { socketPathValue }

    init(store: AgentSessionStore, socketPath: String = AgentSocketPath.path) {
        self.store = store
        self.socketPathValue = socketPath
    }

    func start() {
        // Clean up stale socket
        unlink(socketPath)

        // Set umask to 0o077 BEFORE the listener creates the socket file,
        // ensuring it is never world-readable even briefly (closes TOCTOU window).
        let previousUmask = umask(0o077)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            umask(previousUmask)
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            nonisolated(unsafe) let conn = connection
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }

        let path = socketPath
        listener?.stateUpdateHandler = { [previousUmask] state in
            switch state {
            case .ready:
                // Restore previous umask now that the socket file exists with
                // safe permissions; belt-and-suspenders chmod in case it didn't.
                umask(previousUmask)
                chmod(path, 0o700)
            case .failed:
                umask(previousUmask)
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // Delay socket removal so in-flight hooks can finish sending their
        // payload before the file disappears (upstream #45).
        let path = socketPath
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }

    /// Test seam: wait for the listener to report ready.
    func waitUntilReady(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listener?.state == .ready { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return listener?.state == .ready
    }

    // MARK: - Connection lifecycle

    private static let maxPayloadSize = AgentSessionStore.maxPayloadSize

    private func handleConnection(_ connection: NWConnection) {
        registerDisconnectMonitor(connection)
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    /// Recursively receive all data until EOF, then process. The bridge
    /// half-closes its write side (`shutdown(SHUT_WR)`) after sending the
    /// request, which shows up here as `isComplete` — that is the normal
    /// end-of-payload signal, not a disconnect.
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        nonisolated(unsafe) let conn = connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else {
                    conn.cancel()
                    return
                }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    conn.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    let denyResponse = Data(
                        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
                            .utf8
                    )
                    self.sendResponse(connection: conn, data: denyResponse)
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: conn)
                } else {
                    self.receiveAll(connection: conn, accumulated: data)
                }
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        let origin = ObjectIdentifier(connection)
        Task { @MainActor in
            let response = await self.store.handleConnection(payload: data, origin: origin)
            self.sendResponse(connection: connection, data: response)
        }
    }

    // MARK: - Peer-drop cleanup

    /// Per-connection state: `responded` flips to true once we've sent the
    /// response, so our own `connection.cancel()` inside `sendResponse` does
    /// not masquerade as a peer disconnect.
    private final class ConnectionContext: @unchecked Sendable {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process death — a real socket teardown, NOT the
    /// half-close every bridge does after sending its request (which only
    /// produces receive EOF, see `receiveAll`). A teardown with no response
    /// yet releases the prompts that connection parked, so nothing hangs.
    private func registerDisconnectMonitor(_ connection: NWConnection) {
        let context = ConnectionContext()
        let connectionId = ObjectIdentifier(connection)
        connectionContexts[connectionId] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    let stored = self.connectionContexts.removeValue(forKey: connectionId)
                    if stored != nil, !context.responded {
                        self.store.denyAll(origin: connectionId)
                    }
                default:
                    break
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores
        // our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        nonisolated(unsafe) let conn = connection
        connection.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
