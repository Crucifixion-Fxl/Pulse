import XCTest
import Darwin
@testable import Pulse

/// Temp-HOME fixtures for the agent hook config installer: what ends up in
/// Claude Code's settings.json / Codex's hooks.json + config.toml, what is
/// preserved byte-for-byte, and what uninstall restores.
final class AgentHookConfigInstallerTests: XCTestCase {

    private var fm: FileManager!
    private var tempHome: URL!

    override func setUpWithError() throws {
        fm = FileManager.default
        tempHome = fm.temporaryDirectory
            .appendingPathComponent("doisland-hooks-\(UUID().uuidString)")
        try fm.createDirectory(atPath: tempHome.path, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: tempHome.path)
    }

    // MARK: - Helpers

    private func makeInstaller(
        claudeVersion: String? = "2.1.90",
        claudeConfigDirectory: URL? = nil,
        codexHomeDirectory: URL? = nil
    ) -> AgentHookConfigInstaller {
        var installer = AgentHookConfigInstaller(
            homeDirectory: tempHome,
            claudeConfigDirectory: claudeConfigDirectory,
            codexHomeDirectory: codexHomeDirectory
        )
        installer.claudeVersionProvider = { claudeVersion }
        return installer
    }

    private func write(_ text: String, to path: String) {
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(text.utf8)))
    }

    private func readText(_ path: String) -> String? {
        fm.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Parse like the installer does — the minimal-diff writer preserves the
    /// user's `//` comments, so raw JSONSerialization cannot read its output.
    private func readJSON(_ path: String) -> [String: Any]? {
        AgentHookConfigInstaller.parseJSONFile(at: path, fm: fm)
    }

    /// The hook entries we own under one event key.
    private func ourEntries(in hooks: [String: Any], event: String, bridgePath: String) -> [[String: Any]] {
        guard let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.filter { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
            return hookList.contains { ($0["command"] as? String)?.contains(bridgePath) == true }
        }
    }

    private let userManagedFixture = """
        {
          // user-managed
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/local/bin/user-hook",
                    "timeout": 30
                  }
                ]
              }
            ]
          },
          "permissions": {
            "allow": [
              "Bash(ls:*)"
            ]
          }
        }

        """

    // MARK: - Claude Code

    func testClaudeInstallAddsExactlyOurEventsWithTimeouts() throws {
        let installer = makeInstaller()
        write(userManagedFixture, to: installer.claudeSettingsPath)

        XCTAssertTrue(installer.installClaudeHooks())

        let json = try XCTUnwrap(readJSON(installer.claudeSettingsPath))
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        // Exactly our 13 events on a new-enough version, each with one entry.
        let expectedEvents: Set<String> = [
            "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionStart",
            "SessionEnd", "PreCompact", "PermissionRequest", "Notification",
        ]
        XCTAssertEqual(Set(hooks.keys), expectedEvents)
        let bridgePath = installer.bridgePath
        for event in expectedEvents {
            XCTAssertEqual(ourEntries(in: hooks, event: event, bridgePath: bridgePath).count, 1, event)
        }

        // Timeouts: blocking events wait a day, everything else 5s.
        func timeout(of event: String) -> Int? {
            guard let entry = ourEntries(in: hooks, event: event, bridgePath: bridgePath).first,
                  let hookList = entry["hooks"] as? [[String: Any]],
                  let hook = hookList.first else { return nil }
            return hook["timeout"] as? Int
        }
        XCTAssertEqual(timeout(of: "PermissionRequest"), 86400)
        XCTAssertEqual(timeout(of: "Notification"), 86400)
        XCTAssertEqual(timeout(of: "Stop"), 5)
        XCTAssertEqual(timeout(of: "UserPromptSubmit"), 5)

        // Entry shape: matcher "", type command, command = absolute staged bridge path.
        let ours = try XCTUnwrap(ourEntries(in: hooks, event: "Stop", bridgePath: bridgePath).first)
        XCTAssertEqual(ours["matcher"] as? String, "")
        let hook = try XCTUnwrap((ours["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["type"] as? String, "command")
        let command = try XCTUnwrap(hook["command"] as? String)
        XCTAssertTrue(command.contains(bridgePath), command)

        // The user's own entry survives alongside ours (PreToolUse now has both).
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 2)
        let userEntry = try XCTUnwrap(preToolUse.first { ($0["matcher"] as? String) == "Bash" })
        let userHook = try XCTUnwrap((userEntry["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(userHook["command"] as? String, "/usr/local/bin/user-hook")
        XCTAssertEqual(userHook["timeout"] as? Int, 30)

        // Other top-level keys survive.
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertEqual((json["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
    }

    func testClaudeInstallPreservesSurroundingBytesAndBacksUp() throws {
        let installer = makeInstaller()
        write(userManagedFixture, to: installer.claudeSettingsPath)

        XCTAssertTrue(installer.installClaudeHooks())

        let result = try XCTUnwrap(readText(installer.claudeSettingsPath))

        // Everything before the managed "hooks" value and after it is untouched:
        // the comment, the "model" key, and the whole "permissions" tail survive
        // byte-for-byte (only the "hooks" value itself is rewritten).
        XCTAssertTrue(result.hasPrefix("""
        {
          // user-managed
          "model": "opus",
          "hooks":
        """))
        XCTAssertTrue(result.hasSuffix("""
        ,
          "permissions": {
            "allow": [
              "Bash(ls:*)"
            ]
          }
        }

        """))

        // First modification backs the original up; content matches verbatim.
        let backup = try XCTUnwrap(readText(installer.claudeSettingsPath + ".doisland-backup"))
        XCTAssertEqual(backup, userManagedFixture)
    }

    func testClaudeInstallIsIdempotent() throws {
        let installer = makeInstaller()
        write(userManagedFixture, to: installer.claudeSettingsPath)

        XCTAssertTrue(installer.installClaudeHooks())
        let afterFirst = try XCTUnwrap(fm.contents(atPath: installer.claudeSettingsPath))
        let backupAfterFirst = try XCTUnwrap(readText(installer.claudeSettingsPath + ".doisland-backup"))

        XCTAssertTrue(installer.installClaudeHooks())
        let afterSecond = try XCTUnwrap(fm.contents(atPath: installer.claudeSettingsPath))

        // Second run is a byte-level no-op, and the backup still holds the
        // pre-install original rather than an intermediate state.
        XCTAssertEqual(afterFirst, afterSecond)
        XCTAssertEqual(backupAfterFirst, userManagedFixture)
    }

    func testClaudeInstallCreatesSettingsWhenAbsent() throws {
        let installer = makeInstaller()
        XCTAssertTrue(installer.installClaudeHooks())

        let json = try XCTUnwrap(readJSON(installer.claudeSettingsPath))
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertEqual(hooks.count, 13)
        // No backup for a file that never existed.
        XCTAssertFalse(fm.fileExists(atPath: installer.claudeSettingsPath + ".doisland-backup"))
    }

    func testClaudeVersionGating() throws {
        // Older build: StopFailure (2.1.78) and PostToolUseFailure (2.1.89) stay out.
        let old = makeInstaller(claudeVersion: "2.1.70")
        XCTAssertTrue(old.installClaudeHooks())
        var hooks = try XCTUnwrap(readJSON(old.claudeSettingsPath)?["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys).intersection(["StopFailure", "PostToolUseFailure"]), [])
        XCTAssertEqual(hooks.count, 11)

        // Exactly at the threshold: StopFailure in, PostToolUseFailure out.
        let mid = makeInstaller(claudeVersion: "2.1.78")
        XCTAssertTrue(mid.installClaudeHooks())
        hooks = try XCTUnwrap(readJSON(mid.claudeSettingsPath)?["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["StopFailure"])
        XCTAssertNil(hooks["PostToolUseFailure"])

        // Undetectable version: documented simplification — both included.
        let unknown = makeInstaller(claudeVersion: nil)
        XCTAssertTrue(unknown.installClaudeHooks())
        hooks = try XCTUnwrap(readJSON(unknown.claudeSettingsPath)?["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["StopFailure"])
        XCTAssertNotNil(hooks["PostToolUseFailure"])
    }

    func testClaudeUnparseableJSONUntouched() throws {
        let installer = makeInstaller()
        let garbage = "{ this is not json"
        write(garbage, to: installer.claudeSettingsPath)

        XCTAssertFalse(installer.installClaudeHooks())
        XCTAssertEqual(readText(installer.claudeSettingsPath), garbage)
        // No backup either — we refused to touch the file at all.
        XCTAssertFalse(fm.fileExists(atPath: installer.claudeSettingsPath + ".doisland-backup"))
    }

    func testClaudeUninstallRemovesOursAndKeepsUserHooks() throws {
        let installer = makeInstaller()
        write(userManagedFixture, to: installer.claudeSettingsPath)
        XCTAssertTrue(installer.installClaudeHooks())

        installer.uninstallClaudeHooks()

        let json = try XCTUnwrap(readJSON(installer.claudeSettingsPath))
        // Only the user's PreToolUse entry remains under "hooks".
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["PreToolUse"])
        let entries = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual((entries.first?["matcher"] as? String), "Bash")

        // Unowned keys untouched.
        XCTAssertEqual(json["model"] as? String, "opus")
    }

    func testClaudeUninstallDeletesEmptyHooksKey() throws {
        let installer = makeInstaller()
        XCTAssertTrue(installer.installClaudeHooks())
        installer.uninstallClaudeHooks()

        let text = try XCTUnwrap(readText(installer.claudeSettingsPath))
        XCTAssertFalse(text.contains("\"hooks\""))
        let json = try XCTUnwrap(readJSON(installer.claudeSettingsPath))
        XCTAssertNil(json["hooks"])
    }

    func testClaudeConfigDirectoryIsInjectable() throws {
        let custom = tempHome.appendingPathComponent(".claude-work")
        let installer = makeInstaller(claudeConfigDirectory: custom)
        XCTAssertTrue(installer.installClaudeHooks())

        XCTAssertTrue(fm.fileExists(atPath: custom.appendingPathComponent("settings.json").path))
        XCTAssertFalse(fm.fileExists(atPath: tempHome.appendingPathComponent(".claude").path))
    }

    // MARK: - Codex

    private func makeCodexHome() -> URL {
        let codex = tempHome.appendingPathComponent(".codex")
        try? fm.createDirectory(atPath: codex.path, withIntermediateDirectories: true)
        return codex
    }

    func testCodexInstallWritesNestedHooksAndEnablesToml() throws {
        let codex = makeCodexHome()
        let toml = """
            # user config
            model = "gpt-5"

            [mcp_servers]
            [mcp_servers.fs]
            command = "npx"

            """
        write(toml, to: codex.appendingPathComponent("config.toml").path)

        let installer = makeInstaller()
        XCTAssertTrue(installer.installCodexHooks())

        // hooks.json: nested shape {event: [{hooks: [{type, command, timeout}]}]}
        let hooks = try XCTUnwrap(readJSON(installer.codexHooksPath)?["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            Set(AgentHookConfigInstaller.codexEvents.map(\.event))
        )
        let expectedCommand = "\"\(installer.bridgePath)\" --source codex"
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 1)
        let inner = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(inner.first?["type"] as? String, "command")
        XCTAssertEqual(inner.first?["command"] as? String, expectedCommand)
        XCTAssertEqual(inner.first?["timeout"] as? Int, 5)

        let permission = try XCTUnwrap(ourEntries(in: hooks, event: "PermissionRequest", bridgePath: installer.bridgePath).first)
        let permissionHook = try XCTUnwrap((permission["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(permissionHook["timeout"] as? Int, 86400)

        // config.toml: features.hooks = true as a root-level dotted key (before
        // the first table header), existing content untouched.
        let tomlAfter = try XCTUnwrap(readText(installer.codexConfigTomlPath))
        XCTAssertTrue(tomlAfter.hasPrefix("# user config\nmodel = \"gpt-5\"\n"))
        XCTAssertTrue(tomlAfter.contains("[mcp_servers.fs]\ncommand = \"npx\"\n"))
        let flag = try XCTUnwrap(tomlAfter.range(of: "features.hooks = true"))
        let firstTable = try XCTUnwrap(tomlAfter.range(of: "[mcp_servers]"))
        XCTAssertLessThan(flag.lowerBound, firstTable.lowerBound)
    }

    func testCodexInstallInsertsIntoExistingFeaturesTable() throws {
        let codex = makeCodexHome()
        write("""
            [features]
            codex_exec = true

            [model]
            model = "gpt-5"
            """, to: codex.appendingPathComponent("config.toml").path)

        let installer = makeInstaller()
        XCTAssertTrue(installer.installCodexHooks())

        let toml = try XCTUnwrap(readText(installer.codexConfigTomlPath))
        XCTAssertTrue(toml.contains("[features]\nhooks = true\ncodex_exec = true\n"))
        // No duplicate features table appended at the end.
        XCTAssertEqual(toml.components(separatedBy: "[features]").count - 1, 1)
        XCTAssertTrue(toml.contains("[model]\nmodel = \"gpt-5\""))
    }

    func testCodexSkippedWhenNotInstalled() {
        let installer = makeInstaller() // no ~/.codex in temp home
        XCTAssertTrue(installer.installCodexHooks())
        XCTAssertFalse(fm.fileExists(atPath: installer.codexHooksPath))
        XCTAssertFalse(fm.fileExists(atPath: installer.codexConfigTomlPath))
    }

    func testCodexPreservesForeignHookEntries() throws {
        _ = makeCodexHome()
        let installer = makeInstaller()
        write("""
            {
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "/usr/local/bin/other", "timeout": 9 } ] }
                ]
              }
            }
            """, to: installer.codexHooksPath)

        XCTAssertTrue(installer.installCodexHooks())

        let hooks = try XCTUnwrap(readJSON(installer.codexHooksPath)?["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let other = try XCTUnwrap(stop.first {
            ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/other"
        })
        XCTAssertEqual((other["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 9)

        // Idempotent second run.
        let afterFirst = try XCTUnwrap(fm.contents(atPath: installer.codexHooksPath))
        XCTAssertTrue(installer.installCodexHooks())
        XCTAssertEqual(try XCTUnwrap(fm.contents(atPath: installer.codexHooksPath)), afterFirst)
    }

    func testCodexUnparseableHooksJSONUntouched() throws {
        _ = makeCodexHome()
        let installer = makeInstaller()
        let garbage = "[1, 2,"
        write(garbage, to: installer.codexHooksPath)

        XCTAssertFalse(installer.installCodexHooks())
        XCTAssertEqual(readText(installer.codexHooksPath), garbage)
    }

    func testCodexConflictingTomlIsNotMangled() throws {
        let codex = makeCodexHome()
        // Two [features] tables is a duplicate key Codex refuses to load; our
        // editor must decline rather than add a third spelling.
        let conflicting = "[features]\ncodex_exec = true\n\n[features]\ncodex_web = true\n"
        write(conflicting, to: codex.appendingPathComponent("config.toml").path)

        let installer = makeInstaller()
        XCTAssertFalse(installer.installCodexHooks())
        XCTAssertEqual(readText(installer.codexConfigTomlPath), conflicting)
    }

    func testCodexUninstallRemovesOursAndEmptyHooksKey() throws {
        _ = makeCodexHome()
        let installer = makeInstaller()
        XCTAssertTrue(installer.installCodexHooks())
        installer.uninstallCodexHooks()

        let json = try XCTUnwrap(readJSON(installer.codexHooksPath))
        XCTAssertNil(json["hooks"])
        // The feature flag is left in place (documented deviation: inert
        // without hook entries, and possibly older than our install).
        XCTAssertTrue(readText(installer.codexConfigTomlPath)?.contains("features.hooks = true") == true)
    }

    // MARK: - Bridge staging

    private func makeSourceBinary(name: String = "src-bridge") -> URL {
        let source = tempHome.appendingPathComponent(name)
        fm.createFile(
            atPath: source.path,
            contents: Data("#!/bin/sh\necho v1\n".utf8)
        )
        chmod(source.path, 0o644)
        let quarantine = "0081;6612bcde;Safari;"
        quarantine.withCString { buffer in
            _ = setxattr(source.path, "com.apple.quarantine", buffer, quarantine.utf8.count, 0, 0)
        }
        return source
    }

    func testStageBridgeCopiesChmodsAndStripsQuarantine() throws {
        let installer = makeInstaller()
        let source = makeSourceBinary()

        let staged = try XCTUnwrap(installer.stageBridge(fromBinaryAt: source))
        XCTAssertEqual(staged.path, installer.bridgePath)

        XCTAssertEqual(readText(installer.bridgePath), "#!/bin/sh\necho v1\n")
        let attrs = try XCTUnwrap(fm.attributesOfItem(atPath: installer.bridgePath) as? [FileAttributeKey: Any])
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(getxattr(installer.bridgePath, "com.apple.quarantine", nil, 0, 0, 0), -1)
    }

    func testStageBridgeReplacesPreviousCopy() throws {
        let installer = makeInstaller()
        let source = makeSourceBinary()
        XCTAssertNotNil(installer.stageBridge(fromBinaryAt: source))

        // A newer bundle resource replaces the staged copy in place.
        fm.createFile(atPath: source.path, contents: Data("#!/bin/sh\necho v2\n".utf8))
        XCTAssertNotNil(installer.stageBridge(fromBinaryAt: source))
        XCTAssertEqual(readText(installer.bridgePath), "#!/bin/sh\necho v2\n")
        // No temp leftovers.
        let support = try XCTUnwrap(fm.contentsOfDirectory(atPath: installer.supportDirectory))
        XCTAssertEqual(support, ["agent-bridge"])
    }

    func testStageBridgeFromBundleWithoutResourceReturnsNil() {
        let installer = makeInstaller()
        XCTAssertNil(installer.stageBridge(from: Bundle(for: AgentHookConfigInstallerTests.self)))
        XCTAssertFalse(fm.fileExists(atPath: installer.supportDirectory))
    }

    // MARK: - installAll / uninstallAll

    func testInstallAllRequiresABridge() throws {
        let installer = makeInstaller()
        // No bundle resource and nothing staged yet.
        XCTAssertFalse(installer.installAll(bundle: Bundle(for: AgentHookConfigInstallerTests.self)))
        XCTAssertFalse(fm.fileExists(atPath: installer.claudeSettingsPath))
    }

    func testInstallAllRunsWhenBridgeAlreadyStaged() throws {
        let installer = makeInstaller()
        XCTAssertNotNil(installer.stageBridge(fromBinaryAt: makeSourceBinary()))

        // Bundle without the resource, but the staged binary exists — install proceeds.
        XCTAssertTrue(installer.installAll(bundle: Bundle(for: AgentHookConfigInstallerTests.self)))
        XCTAssertTrue(fm.fileExists(atPath: installer.claudeSettingsPath))
        // Codex home does not exist in the temp HOME — skipped silently.
        XCTAssertFalse(fm.fileExists(atPath: installer.codexHooksPath))
    }

    func testUninstallAllCleansStagedBridgeAndBackup() throws {
        _ = makeCodexHome()
        let installer = makeInstaller()
        XCTAssertNotNil(installer.stageBridge(fromBinaryAt: makeSourceBinary()))
        write(userManagedFixture, to: installer.claudeSettingsPath) // so a backup gets made
        XCTAssertTrue(installer.installAll(bundle: Bundle(for: AgentHookConfigInstallerTests.self)))
        XCTAssertTrue(fm.fileExists(atPath: installer.claudeSettingsPath + ".doisland-backup"))

        installer.uninstallAll()

        // Our entries are gone (the fixture's own user hook may remain),
        // along with the staged bridge and the backup.
        XCTAssertFalse(readText(installer.claudeSettingsPath)?.contains(installer.bridgePath) == true)
        XCTAssertNil(readJSON(installer.codexHooksPath)?["hooks"])
        XCTAssertFalse(fm.fileExists(atPath: installer.bridgePath))
        XCTAssertFalse(fm.fileExists(atPath: installer.claudeSettingsPath + ".doisland-backup"))
    }
}
