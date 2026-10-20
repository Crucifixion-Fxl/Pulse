// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIslandCore/SocketPath.swift, adapted: env key + socket name prefixed doisland)

import Foundation
import Darwin

/// Unix domain socket the agent hook bridge connects to.
enum AgentSocketPath {
    static var path: String {
        if let env = ProcessInfo.processInfo.environment["DOISLAND_AGENTS_SOCKET_PATH"] {
            return env
        }
        return "/tmp/doisland-agents-\(getuid()).sock"
    }
}
