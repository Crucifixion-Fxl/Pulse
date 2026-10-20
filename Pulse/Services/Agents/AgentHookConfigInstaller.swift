// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIsland/JSONMinimalEditor.swift verbatim; Sources/CodeIslandCore/CodexHooksConfig.swift
// verbatim; the Claude Code + Codex paths of Sources/CodeIsland/ConfigInstaller.swift)
//
// Trimmed for this port — only Claude Code and Codex are installed:
// • Claude config dir: $CLAUDE_CONFIG_DIR (with `~` expanded), else ~/.claude.
//   CodeIsland's UserDefaults preference rung and ~/.config/claude[-code]
//   probing are dropped (simplification; the env var covers shell launches).
// • Codex home: $CODEX_HOME, else ~/.codex — both injectable for tests.
// • Claude Code version gating: when `claude --version` answers, PostToolUseFailure
//   (≥ 2.1.89) and StopFailure (≥ 2.1.78) are written only for new enough builds.
//   Simplification vs CodeIsland (which SKIPS gated events on an undetectable
//   version): an unknown version includes both — an unknown hook key is ignored
//   by older builds, and the alternative would silently drop turn-failure
//   signals on every machine where the binary isn't on the probe path.
// • The bridge ships as a bundle resource (Pulse/Resources/Helpers/AgentHookBridge,
//   built by scripts/build-agent-bridge.sh) and is staged into
//   ~/Library/Application Support/TodoIsland/agent-bridge; hook commands point
//   at the staged copy so app updates re-stage in place without touching configs.
// • Uninstall removes our hook entries and the staged bridge, but leaves Codex's
//   `features.hooks` flag in config.toml as-is: without hook entries the flag is
//   inert, and we cannot tell a flag we set from one the user relies on.

import Foundation
import Darwin

// MARK: - JSONMinimalEditor

/// Minimal-diff editor for JSON / JSONC config files.
///
/// Unlike `JSONSerialization.data(...) -> write` which rewrites the whole
/// document (losing comments, reordering keys, escaping slashes, dropping
/// trailing newlines), this editor only replaces the text range of the
/// target top-level key's value. Every other byte of the file stays put.
///
/// Used by `AgentHookConfigInstaller` to manage the `hooks` entries
/// without disturbing user-authored config around them (CodeIsland #105/#106/#119).
enum JSONMinimalEditor {

    // MARK: - Public API

    /// Set (insert or replace) the value of `key` at the top level of `source`.
    ///
    /// - Parameters:
    ///   - source: Original JSON/JSONC text.
    ///   - key: Top-level key to write.
    ///   - value: Any `JSONSerialization`-compatible Swift value (dict, array, string, number, bool, NSNull).
    /// - Returns: New document text, or `nil` if `source` is not a valid JSON *object* at the top level
    ///   (caller MUST NOT overwrite on nil — CodeIsland #89)
    static func setTopLevelValue(in source: String, key: String, value: Any) -> String? {
        let chars = Array(source)
        guard let doc = parseTopLevelObject(chars: chars) else { return nil }

        let indent = detectKeyIndent(chars: chars, doc: doc)
        guard let serialized = serializeValue(value, keyIndent: indent) else { return nil }

        if let entry = doc.entries.first(where: { $0.key == key }) {
            // Replace value text range only.
            let prefix = String(chars[..<entry.valueStart])
            let suffix = String(chars[entry.valueEnd...])
            return prefix + serialized + suffix
        }
        return insertKey(chars: chars, doc: doc, key: key, serialized: serialized, keyIndent: indent)
    }

    /// Delete a top-level `key` from `source`. Returns `source` unchanged if key missing.
    /// Returns `nil` if `source` is not a valid JSON object at top level.
    static func deleteTopLevelKey(in source: String, key: String) -> String? {
        let chars = Array(source)
        guard let doc = parseTopLevelObject(chars: chars) else { return nil }
        guard let idx = doc.entries.firstIndex(where: { $0.key == key }) else { return source }
        let entry = doc.entries[idx]

        // Compute removal range including adjoining comma.
        var removeStart = entry.keyStart
        var removeEnd = entry.valueEnd

        if doc.entries.count == 1 {
            // Only entry — remove everything between `{` and `}`, leaving an empty object.
            removeStart = doc.objectContentStart
            removeEnd = doc.objectContentEnd
        } else if idx < doc.entries.count - 1 {
            // Not the last entry — extend to trailing comma (+ whitespace/newline up to next entry start).
            let nextStart = doc.entries[idx + 1].keyStart
            // Find the `,` after entry.valueEnd.
            if let commaIdx = findNextNonSpace(chars: chars, from: entry.valueEnd, stopAt: nextStart), chars[commaIdx] == "," {
                removeEnd = commaIdx + 1
                // Also swallow whitespace up to next entry start so the next entry's own indent is preserved.
                while removeEnd < nextStart,
                      chars[removeEnd] == " " || chars[removeEnd] == "\t" {
                    removeEnd += 1
                }
                if removeEnd < nextStart, chars[removeEnd] == "\n" {
                    removeEnd += 1
                }
            }
        } else {
            // Last entry — strip the preceding comma from the previous entry.
            let prev = doc.entries[idx - 1]
            if let commaIdx = findPrevNonSpace(chars: chars, from: entry.keyStart, stopAt: prev.valueEnd),
               chars[commaIdx] == "," {
                removeStart = commaIdx
            } else {
                // No trailing comma (shouldn't happen in valid JSON with >1 entry), keep entry start.
            }
        }

        // Swallow trailing newline after the removed block only if the removed block ends on a line of its own.
        let prefix = String(chars[..<removeStart])
        let suffix = String(chars[removeEnd...])
        return prefix + suffix
    }

    // MARK: - Document model

    private struct Entry {
        let key: String
        let keyStart: Int   // index of opening `"` of the key literal
        let valueStart: Int // index of first char of the value (after `:` and whitespace)
        let valueEnd: Int   // exclusive
    }

    private struct Document {
        let objectContentStart: Int  // index just after the opening `{`
        let objectContentEnd: Int    // index of the matching `}`
        let entries: [Entry]
    }

    // MARK: - Parser

    private static func parseTopLevelObject(chars: [Character]) -> Document? {
        var i = 0
        skipSpace(chars: chars, i: &i)
        guard i < chars.count, chars[i] == "{" else { return nil }
        let openBrace = i
        i += 1

        var entries: [Entry] = []
        var expectEntry = true

        while true {
            skipSpace(chars: chars, i: &i)
            guard i < chars.count else { return nil }
            if chars[i] == "}" {
                let closeBrace = i
                return Document(
                    objectContentStart: openBrace + 1,
                    objectContentEnd: closeBrace,
                    entries: entries
                )
            }
            if !expectEntry {
                return nil // missing comma
            }

            // Parse key
            guard i < chars.count, chars[i] == "\"" else { return nil }
            let keyStart = i
            guard let keyValue = readStringLiteral(chars: chars, i: &i) else { return nil }

            skipSpace(chars: chars, i: &i)
            guard i < chars.count, chars[i] == ":" else { return nil }
            i += 1
            skipSpace(chars: chars, i: &i)

            let valueStart = i
            guard skipValue(chars: chars, i: &i) else { return nil }
            let valueEnd = i

            entries.append(Entry(key: keyValue, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))

            skipSpace(chars: chars, i: &i)
            if i < chars.count, chars[i] == "," {
                i += 1
                expectEntry = true
                continue
            }
            expectEntry = false
        }
    }

    // MARK: - Scanning primitives

    private static func skipSpace(chars: [Character], i: inout Int) {
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                i += 2
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count {
                    if chars[i] == "*" && chars[i + 1] == "/" { i += 2; break }
                    i += 1
                }
                continue
            }
            break
        }
    }

    /// Reads a JSON string literal starting at `i`, returns the parsed value and advances `i` past the closing `"`.
    private static func readStringLiteral(chars: [Character], i: inout Int) -> String? {
        guard i < chars.count, chars[i] == "\"" else { return nil }
        i += 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count else { return nil }
                let esc = chars[i + 1]
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/":  out.append("/")
                case "b":  out.append("\u{08}")
                case "f":  out.append("\u{0C}")
                case "n":  out.append("\n")
                case "r":  out.append("\r")
                case "t":  out.append("\t")
                case "u":
                    guard i + 5 < chars.count else { return nil }
                    let hex = String(chars[(i + 2)...(i + 5)])
                    guard let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) else { return nil }
                    out.append(Character(scalar))
                    i += 6
                    continue
                default: out.append(esc)
                }
                i += 2
                continue
            }
            if c == "\"" { i += 1; return out }
            out.append(c)
            i += 1
        }
        return nil
    }

    /// Advances `i` past a JSON value. Does not parse — only skips to the end.
    private static func skipValue(chars: [Character], i: inout Int) -> Bool {
        skipSpace(chars: chars, i: &i)
        guard i < chars.count else { return false }
        let c = chars[i]
        switch c {
        case "\"":
            return readStringLiteral(chars: chars, i: &i) != nil
        case "{":
            return skipObjectOrArray(chars: chars, i: &i, open: "{", close: "}")
        case "[":
            return skipObjectOrArray(chars: chars, i: &i, open: "[", close: "]")
        case "t", "f", "n":
            while i < chars.count, chars[i].isLetter { i += 1 }
            return true
        case "-", "+", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            while i < chars.count {
                let cc = chars[i]
                if cc.isNumber || cc == "." || cc == "e" || cc == "E" || cc == "-" || cc == "+" {
                    i += 1
                } else { break }
            }
            return true
        default:
            return false
        }
    }

    private static func skipObjectOrArray(chars: [Character], i: inout Int, open: Character, close: Character) -> Bool {
        guard i < chars.count, chars[i] == open else { return false }
        i += 1
        var depth = 1
        while i < chars.count, depth > 0 {
            let c = chars[i]
            if c == "\"" {
                if readStringLiteral(chars: chars, i: &i) == nil { return false }
                continue
            }
            if c == "/", i + 1 < chars.count, (chars[i + 1] == "/" || chars[i + 1] == "*") {
                skipSpace(chars: chars, i: &i)
                continue
            }
            if c == open || c == "{" || c == "[" { depth += 1 }
            else if c == close || c == "}" || c == "]" {
                // Generic `{`/`[` -> `}`/`]` matching is sloppy for mixed nesting, but JSON
                // nesting is well-formed so we rely on each opener pairing with its own closer.
                depth -= 1
                if depth == 0 { i += 1; return true }
            }
            i += 1
        }
        return depth == 0
    }

    private static func findNextNonSpace(chars: [Character], from: Int, stopAt: Int) -> Int? {
        var i = from
        while i < stopAt {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            if c == "/", i + 1 < stopAt, chars[i + 1] == "/" {
                i += 2
                while i < stopAt && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < stopAt, chars[i + 1] == "*" {
                i += 2
                while i + 1 < stopAt {
                    if chars[i] == "*" && chars[i + 1] == "/" { i += 2; break }
                    i += 1
                }
                continue
            }
            return i
        }
        return nil
    }

    private static func findPrevNonSpace(chars: [Character], from: Int, stopAt: Int) -> Int? {
        var i = from - 1
        while i >= stopAt {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i -= 1; continue }
            return i
        }
        return nil
    }

    // MARK: - Indent detection

    private static func detectKeyIndent(chars: [Character], doc: Document) -> String {
        // Prefer the indent of the first entry.
        if let first = doc.entries.first {
            var start = first.keyStart
            while start > 0 && chars[start - 1] != "\n" { start -= 1 }
            let prefix = chars[start..<first.keyStart]
            if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                return String(prefix)
            }
        }
        // Fallback: indent of closing `}` + 2 spaces.
        var start = doc.objectContentEnd
        while start > 0 && chars[start - 1] != "\n" { start -= 1 }
        let prefix = chars[start..<doc.objectContentEnd]
        if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
            return String(prefix) + "  "
        }
        return "  "
    }

    private static func closingBraceIndent(chars: [Character], doc: Document) -> String {
        var start = doc.objectContentEnd
        while start > 0 && chars[start - 1] != "\n" { start -= 1 }
        let prefix = chars[start..<doc.objectContentEnd]
        if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
            return String(prefix)
        }
        return ""
    }

    // MARK: - Insertion

    private static func insertKey(chars: [Character], doc: Document, key: String, serialized: String, keyIndent: String) -> String? {
        let closingIndent = closingBraceIndent(chars: chars, doc: doc)
        let entry = "\"\(escape(key))\": \(serialized)"

        if doc.entries.isEmpty {
            // `{}` or `{   }` -> replace content with a single entry.
            let prefix = String(chars[...(doc.objectContentStart - 1)])
            let suffix = String(chars[doc.objectContentEnd...])
            return prefix + "\n\(keyIndent)\(entry)\n\(closingIndent)" + suffix
        }

        // Append after the last entry's value, before the closing `}`.
        let last = doc.entries.last!
        // Everything from last.valueEnd up to doc.objectContentEnd (the `}`) is whitespace/comments.
        // Insert `,\n<indent><entry>` right after last.valueEnd, keeping the trailing whitespace intact.
        let insertPoint = last.valueEnd
        let prefix = String(chars[..<insertPoint])
        let suffix = String(chars[insertPoint...])
        // Determine the newline style: does the existing content between last entry and `}` contain a newline?
        let tail = chars[last.valueEnd..<doc.objectContentEnd]
        let hasNewline = tail.contains("\n")
        let inserted = hasNewline ? ",\n\(keyIndent)\(entry)" : ",\n\(keyIndent)\(entry)\n\(closingIndent)"
        if !hasNewline {
            // Need to also strip trailing spaces in `suffix` before the `}` so the closing brace sits on its own line.
            // But to keep behavior minimal, insert with explicit newlines regardless.
            return prefix + inserted + suffix
        }
        return prefix + inserted + suffix
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - Value serialization

    /// Serialize a Swift value to JSON text suitable for embedding at an indented position.
    /// - Parameter keyIndent: The indentation of the key's own line; nested lines get the same prefix.
    /// - Returns: JSON text ready to be placed after `"key": `, or `nil` if the value cannot be serialized.
    ///
    /// Intentionally omits `.sortedKeys` so NSDictionary iteration order is preserved (unstable for dicts we
    /// constructed ourselves, but stable enough to not force alphabetical reordering of user-adjacent data).
    static func serializeValue(_ value: Any, keyIndent: String) -> String? {
        if JSONSerialization.isValidJSONObject(value) {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: opts),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            return reindent(raw, keyIndent: keyIndent)
        }
        return serializePrimitive(value)
    }

    private static func serializePrimitive(_ value: Any) -> String? {
        // JSONSerialization's top-level must be object/array; wrap in `[value]` and strip outer brackets.
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              var raw = String(data: data, encoding: .utf8) else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        raw.removeFirst()
        raw.removeLast()
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-indent a pretty-printed JSON string so its leading edge aligns with the containing key's indent.
    /// `raw` starts with 0-indent (as produced by JSONSerialization). We prepend `keyIndent` to every line
    /// *except* the first, so the value lines up inside its parent object.
    private static func reindent(_ raw: String, keyIndent: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        guard lines.count > 1 else { return raw }
        for idx in 1..<lines.count {
            if !lines[idx].isEmpty {
                lines[idx] = keyIndent + lines[idx]
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - CodexHooksConfig

/// Source-preserving editor for the root Codex hooks feature flag (CodeIsland #354).
/// This is deliberately not a general TOML parser: values remain opaque, and
/// conflicting/unsupported layouts return nil rather than risk a duplicate key.
enum CodexHooksConfig {
    static func enablingHooks(in contents: String) -> String? {
        try? Scanner(contents).enablingHooks()
    }

    private enum Invalid: Error { case layout }

    private struct Flag {
        let statement: Range<Int>
        let key: Range<Int>
        let value: Range<Int>
        let keyCount: Int
    }

    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    private struct Scanner {
        let contents: String
        let source: [Unicode.Scalar]

        init(_ contents: String) {
            self.contents = contents
            source = Array(contents.unicodeScalars)
        }

        func enablingHooks(healing: Bool = true) throws -> String {
            let statements = try statements()
            if healing, let healed = try withoutAppendedFeaturesTable(statements) {
                return try Scanner(healed).enablingHooks(healing: false)
            }
            var scope: [String] = []
            var current: Flag?
            var legacy: Flag?
            var featuresHeader: Int?
            var firstTable: Int?
            var rootDottedFeatures = false
            for statement in statements {
                var i = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { continue }
                if source[i] == "[" {
                    let array = i + 1 < statement.upperBound && source[i + 1] == "["
                    let parsed = try key(at: i + (array ? 2 : 1), limit: statement.upperBound)
                    let close = parsed.next
                    guard close < statement.upperBound, source[close] == "]",
                          !array || (close + 1 < statement.upperBound && source[close + 1] == "]"),
                          tail(at: close + (array ? 2 : 1), limit: statement.upperBound) else { throw Invalid.layout }
                    scope = parsed.path
                    guard Array(scope.prefix(2)) != ["features", "hooks"],
                          !(array && scope == ["features"]) else { throw Invalid.layout }
                    if firstTable == nil { firstTable = statement.lowerBound }
                    if scope == ["features"] {
                        guard featuresHeader == nil else { throw Invalid.layout }
                        featuresHeader = statement.upperBound
                    }
                    continue
                }
                let keyStart = i
                let parsed = try key(at: i, limit: statement.upperBound)
                i = parsed.next
                guard i < statement.upperBound, source[i] == "=" else { throw Invalid.layout }
                i = skipSpaces(i + 1, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { throw Invalid.layout }
                if scope.isEmpty && parsed.path.count > 1 && parsed.path[0] == "features" { rootDottedFeatures = true }
                let absolute = scope + parsed.path
                guard absolute != ["features"],
                      !(Array(absolute.prefix(2)) == ["features", "hooks"] && absolute.count > 2) else { throw Invalid.layout }
                guard absolute == ["features", "hooks"] || absolute == ["features", "codex_hooks"] else { continue }
                guard let value = ["true", "false"].first(where: {
                    matches($0, at: i, limit: statement.upperBound) && tail(at: i + $0.count, limit: statement.upperBound)
                }) else { throw Invalid.layout }
                let flag = Flag(statement: statement, key: keyStart..<parsed.end, value: i..<(i + value.count), keyCount: parsed.path.count)
                if absolute == ["features", "hooks"] {
                    guard current == nil else { throw Invalid.layout }
                    current = flag
                } else {
                    guard legacy == nil else { throw Invalid.layout }
                    legacy = flag
                }
            }
            // Root dotted `features.*` keys already define the table, so an
            // explicit [features] header too is a duplicate key Codex refuses
            // to load. Don't report such a file as enabled.
            guard featuresHeader == nil || !rootDottedFeatures else { throw Invalid.layout }

            var edits: [Edit] = []
            if let current {
                edits.append(Edit(range: current.value, replacement: "true"))
                if let legacy { edits.append(Edit(range: legacy.statement, replacement: "")) }
            } else if let legacy {
                edits.append(Edit(range: legacy.key, replacement: legacy.keyCount == 1 ? "hooks" : "features.hooks"))
                edits.append(Edit(range: legacy.value, replacement: "true"))
            } else {
                let newline = contents.contains("\r\n") ? "\r\n" : "\n"
                let position: Int
                let addition: String
                if let featuresHeader {
                    position = featuresHeader
                    addition = (position > 0 && source[position - 1] == "\n" ? "" : newline) + "hooks = true" + newline
                } else if let firstTable {
                    position = firstTable
                    addition = "features.hooks = true" + newline
                } else {
                    position = source.count
                    addition = (!source.isEmpty && source.last != "\n" ? newline : "") + "features.hooks = true" + newline
                }
                edits.append(Edit(range: position..<position, replacement: addition))
            }
            var result = source
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                result.replaceSubrange(edit.range, with: edit.replacement.unicodeScalars)
            }
            return String(String.UnicodeScalarView(result))
        }

        /// CodeIsland 1.0.35 and earlier appended `[features]` + `hooks = true`
        /// at EOF whenever its line regex missed the flag or the header, even
        /// when root dotted `features.*` keys or a spelling such as
        /// `[features] # note` already defined that table: a duplicate key that
        /// stops Codex from starting (#354). Returns the document without that
        /// block (and the blank line before it), or nil unless the file ends
        /// with exactly that shape on top of an existing features table.
        func withoutAppendedFeaturesTable(_ statements: [Range<Int>]) throws -> String? {
            var featuresDefined = false
            var lastHeader: Int?
            for (index, statement) in statements.enumerated() {
                let i = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { continue }
                if source[i] == "[" {
                    // Every header but the final one may be the earlier definition.
                    if let previous = lastHeader, try isFeaturesHeader(statements[previous]) { featuresDefined = true }
                    lastHeader = index
                } else if lastHeader == nil {
                    let path = try key(at: i, limit: statement.upperBound).path
                    if path.count > 1 && path[0] == "features" { featuresDefined = true }
                }
            }
            guard featuresDefined, let lastHeader else { return nil }
            let header = statements[lastHeader]
            let open = skipSpaces(header.lowerBound, limit: header.upperBound)
            guard matches("[features]", at: open, limit: header.upperBound),
                  isBlank(open + 10..<header.upperBound) else { return nil }
            var flags = 0
            for statement in statements[(lastHeader + 1)...] where !isBlank(statement) {
                let first = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard source[first] != "#" else { return nil }
                let assignment = try key(at: first, limit: statement.upperBound)
                guard assignment.path == ["hooks"], assignment.next < statement.upperBound,
                      source[assignment.next] == "=" else { return nil }
                let value = skipSpaces(assignment.next + 1, limit: statement.upperBound)
                guard ["true", "false"].contains(where: {
                    matches($0, at: value, limit: statement.upperBound)
                        && isBlank(value + $0.unicodeScalars.count..<statement.upperBound)
                }) else { return nil }
                flags += 1
            }
            guard flags == 1 else { return nil }
            var start = header.lowerBound
            if lastHeader > 0, isBlank(statements[lastHeader - 1]) { start = statements[lastHeader - 1].lowerBound }
            return String(String.UnicodeScalarView(source[..<start]))
        }

        /// `[features]` in any spelling (quoted, spaced, commented); not `[[features]]`.
        func isFeaturesHeader(_ statement: Range<Int>) throws -> Bool {
            let open = skipSpaces(statement.lowerBound, limit: statement.upperBound)
            guard open + 1 < statement.upperBound, source[open + 1] != "[" else { return false }
            let parsed = try key(at: open + 1, limit: statement.upperBound)
            return parsed.path == ["features"] && parsed.next < statement.upperBound && source[parsed.next] == "]"
        }

        func isBlank(_ range: Range<Int>) -> Bool {
            source[range].allSatisfy { [32, 9, 13, 10].contains($0.value) }
        }

        /// Newlines inside strings or nested array/inline-table values do not
        /// start a new statement. Ranges retain comments and line endings.
        func statements() throws -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var stack: [Unicode.Scalar] = []
            var start = 0
            var i = 0
            while i < source.count {
                let ch = source[i]
                if ch == "\"" || ch == "'" {
                    i = try string(at: i, limit: source.count, multiline: true).end
                    continue
                }
                if ch == "#" {
                    while i < source.count && source[i] != "\n" { i += 1 }
                    continue
                }
                if ch == "[" || ch == "{" {
                    stack.append(ch)
                } else if ch == "]" || ch == "}" {
                    guard stack.popLast() == (ch == "]" ? "[" : "{") else { throw Invalid.layout }
                } else if ch == "\r" {
                    guard i + 1 < source.count, source[i + 1] == "\n" else { throw Invalid.layout }
                } else if isControl(ch) {
                    throw Invalid.layout
                }
                if ch == "\n" && stack.isEmpty {
                    ranges.append(start..<(i + 1))
                    start = i + 1
                }
                i += 1
            }
            guard stack.isEmpty else { throw Invalid.layout }
            if start < source.count { ranges.append(start..<source.count) }
            return ranges
        }

        func key(at start: Int, limit: Int) throws -> (path: [String], end: Int, next: Int) {
            var path: [String] = []
            var i = start
            while true {
                i = skipSpaces(i, limit: limit)
                guard i < limit else { throw Invalid.layout }
                if source[i] == "\"" || source[i] == "'" {
                    let parsed = try string(at: i, limit: limit)
                    path.append(parsed.value)
                    i = parsed.end
                } else {
                    let begin = i
                    while i < limit && isBareKey(source[i]) { i += 1 }
                    guard i > begin else { throw Invalid.layout }
                    path.append(String(String.UnicodeScalarView(source[begin..<i])))
                }
                let end = i
                i = skipSpaces(i, limit: limit)
                if i == limit || source[i] != "." { return (path, end, i) }
                i += 1
            }
        }

        func string(at start: Int, limit: Int, multiline: Bool = false) throws -> (end: Int, value: String) {
            let quote = source[start]
            let triple = start + 2 < limit && source[start + 1] == quote && source[start + 2] == quote
            guard !triple || multiline else { throw Invalid.layout }
            var i = start + (triple ? 3 : 1)
            var out: [Unicode.Scalar] = []
            while i < limit {
                let ch = source[i]
                if ch == quote {
                    var end = i + 1
                    if triple {
                        while end < limit && source[end] == quote { end += 1 }
                        let count = end - i
                        if count < 3 {
                            out.append(contentsOf: repeatElement(quote, count: count))
                            i = end
                            continue
                        }
                        guard count <= 5 else { throw Invalid.layout }
                        out.append(contentsOf: repeatElement(quote, count: count - 3))
                    }
                    return (end, String(String.UnicodeScalarView(out)))
                }
                if ch == "\\" && quote == "\"" {
                    i += 1
                    guard i < limit else { throw Invalid.layout }
                    let escaped = source[i]
                    if triple && [32, 9, 13, 10].contains(escaped.value) {
                        var sawNewline = false
                        while i < limit && [32, 9, 13, 10].contains(source[i].value) {
                            if source[i] == "\r" {
                                guard i + 1 < limit, source[i + 1] == "\n" else { throw Invalid.layout }
                            }
                            sawNewline = sawNewline || source[i] == "\n"
                            i += 1
                        }
                        guard sawNewline else { throw Invalid.layout }
                        continue
                    }
                    let escapes: [Unicode.Scalar: Unicode.Scalar] = ["b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{C}", "r": "\r", "\"": "\"", "\\": "\\"]
                    if let value = escapes[escaped] {
                        out.append(value)
                        i += 1
                        continue
                    }
                    if escaped == "u" || escaped == "U" {
                        let end = i + (escaped == "u" ? 5 : 9)
                        guard end <= limit else { throw Invalid.layout }
                        let digits = String(String.UnicodeScalarView(source[(i + 1)..<end]))
                        guard digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
                              let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { throw Invalid.layout }
                        out.append(scalar)
                        i = end
                        continue
                    }
                    throw Invalid.layout
                }
                guard triple || (ch != "\r" && ch != "\n"), !isControl(ch) else { throw Invalid.layout }
                if ch == "\r" {
                    guard i + 1 < limit, source[i + 1] == "\n" else { throw Invalid.layout }
                }
                out.append(ch)
                i += 1
            }
            throw Invalid.layout
        }

        func skipSpaces(_ start: Int, limit: Int) -> Int {
            var i = start
            while i < limit && (source[i] == " " || source[i] == "\t") { i += 1 }
            return i
        }

        func tail(at start: Int, limit: Int) -> Bool {
            var i = start
            while i < limit && [32, 9, 13, 10].contains(source[i].value) { i += 1 }
            return i == limit || source[i] == "#"
        }

        func matches(_ text: String, at start: Int, limit: Int) -> Bool {
            let scalars = Array(text.unicodeScalars)
            return start + scalars.count <= limit && source[start..<(start + scalars.count)].elementsEqual(scalars)
        }

        func isBareKey(_ ch: Unicode.Scalar) -> Bool {
            (48...57).contains(ch.value) || (65...90).contains(ch.value) || (97...122).contains(ch.value) || ch == "_" || ch == "-"
        }

        func isControl(_ ch: Unicode.Scalar) -> Bool {
            (ch.value < 32 && ![9, 13, 10].contains(ch.value)) || ch.value == 127
        }
    }
}

// MARK: - AgentHookConfigInstaller

/// Installs and removes the doisland agent-hook bridge entries for Claude Code
/// and Codex. Re-running `installAll()` on every launch is safe — each pass
/// self-repairs drift (stale entries, missing events) and is a byte-level no-op
/// when everything is already in place.
struct AgentHookConfigInstaller {

    // MARK: Events

    /// Claude Code hook events and their timeouts (seconds). Blocking events
    /// (PermissionRequest, Notification-with-question) wait up to a day for the
    /// user's island decision; everything else answers fast.
    static let claudeEvents: [(event: String, timeout: Int)] = [
        ("UserPromptSubmit", 5),
        ("PreToolUse", 5),
        ("PostToolUse", 5),
        ("PostToolUseFailure", 5),
        ("Stop", 5),
        ("StopFailure", 5),
        ("SubagentStart", 5),
        ("SubagentStop", 5),
        ("SessionStart", 5),
        ("SessionEnd", 5),
        ("PreCompact", 5),
        ("PermissionRequest", 86400),
        ("Notification", 86400),
    ]

    /// Events only valid from a minimum Claude Code version (see the header for
    /// the unknown-version simplification).
    static let claudeVersionGatedEvents: [String: String] = [
        "PostToolUseFailure": "2.1.89",
        "StopFailure": "2.1.78",
    ]

    /// Codex hook events (nested hooks.json shape has no async flag).
    static let codexEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 5),
        ("SessionEnd", 3),
        ("UserPromptSubmit", 5),
        ("PreToolUse", 5),
        ("PostToolUse", 5),
        // Codex fires PermissionRequest before shell escalation /
        // managed-network approvals — a blocking approval hook (CodeIsland #145).
        ("PermissionRequest", 86400),
        ("PreCompact", 5),
        ("PostCompact", 5),
        ("SubagentStart", 5),
        ("SubagentStop", 5),
        ("Stop", 5),
        ("Interrupt", 3),
    ]

    // MARK: Paths

    let homeDirectory: String
    let claudeConfigDirectory: String
    let codexHomeDirectory: String

    /// How version gating learns the installed Claude Code version; injectable
    /// so tests stay hermetic.
    var claudeVersionProvider: () -> String?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeConfigDirectory: URL? = nil,
        codexHomeDirectory: URL? = nil
    ) {
        let home = homeDirectory.path
        self.homeDirectory = home
        if let claudeConfigDirectory {
            self.claudeConfigDirectory = claudeConfigDirectory.path
        } else {
            self.claudeConfigDirectory = Self.resolvingConfigDir(
                envKey: "CLAUDE_CONFIG_DIR", home: home, fallback: ".claude"
            )
        }
        if let codexHomeDirectory {
            self.codexHomeDirectory = codexHomeDirectory.path
        } else {
            self.codexHomeDirectory = Self.resolvingConfigDir(
                envKey: "CODEX_HOME", home: home, fallback: ".codex"
            )
        }
        let detectedHome = home
        self.claudeVersionProvider = { Self.detectClaudeVersion(homeDirectory: detectedHome) }
    }

    private static func resolvingConfigDir(envKey: String, home: String, fallback: String) -> String {
        let raw = (ProcessInfo.processInfo.environment[envKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return home + "/" + fallback }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + "/" + raw.dropFirst(2) }
        return raw
    }

    /// Where the bridge is staged; every hook command points at this copy.
    var supportDirectory: String { homeDirectory + "/Library/Application Support/TodoIsland" }
    var bridgePath: String { supportDirectory + "/agent-bridge" }
    var claudeSettingsPath: String { claudeConfigDirectory + "/settings.json" }
    private var claudeSettingsBackupPath: String { claudeSettingsPath + ".doisland-backup" }
    var codexHooksPath: String { codexHomeDirectory + "/hooks.json" }
    var codexConfigTomlPath: String { codexHomeDirectory + "/config.toml" }

    /// The Claude hook command: the staged bridge, quoted when needed. No
    /// `--source` — Claude Code invokes hooks with the CLI itself as the parent
    /// process, and the bridge infers the source from the ancestry (which also
    /// resolves the PID it reports).
    var claudeHookCommand: String {
        bridgePath.contains(" ") ? "\"\(bridgePath)\"" : bridgePath
    }

    /// The Codex hook command (its payload carries no source marker).
    var codexHookCommand: String { "\(claudeHookCommand) --source codex" }

    // MARK: - Bridge staging

    /// Copy the bundled bridge binary (Pulse/Resources/Helpers/AgentHookBridge) to
    /// `~/Library/Application Support/TodoIsland/agent-bridge`, chmod 0755, and
    /// strip the quarantine xattr. Returns the staged URL, or nil when the
    /// bundle carries no bridge.
    @discardableResult
    func stageBridge(from bundle: Bundle, fm: FileManager = .default) -> URL? {
        guard let url = bundle.url(forResource: "AgentHookBridge", withExtension: nil) else { return nil }
        return stageBridge(fromBinaryAt: url, fm: fm)
    }

    /// Staging core, testable with an arbitrary source file.
    @discardableResult
    func stageBridge(fromBinaryAt source: URL, fm: FileManager = .default) -> URL? {
        guard fm.fileExists(atPath: source.path) else { return nil }
        try? fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)

        // Atomic replace: copy to temp file first, then rename (overwrites atomically)
        let tmpPath = bridgePath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try? fm.removeItem(atPath: tmpPath)
            try fm.copyItem(at: source, to: URL(fileURLWithPath: tmpPath))
            chmod(tmpPath, 0o755)
            // Strip quarantine xattr so Gatekeeper won't block the binary
            stripQuarantine(tmpPath)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: bridgePath), withItemAt: URL(fileURLWithPath: tmpPath))
        } catch {
            // replaceItemAt fails if destination doesn't exist yet — fall back to rename
            try? fm.moveItem(atPath: tmpPath, toPath: bridgePath)
        }
        chmod(bridgePath, 0o755)
        // Ensure final binary is free of quarantine (covers both paths above)
        stripQuarantine(bridgePath)
        return fm.fileExists(atPath: bridgePath) ? URL(fileURLWithPath: bridgePath) : nil
    }

    /// Remove com.apple.quarantine xattr so Gatekeeper won't block the binary.
    /// Copied binaries inherit quarantine from the source app bundle.
    private func stripQuarantine(_ path: String) {
        removexattr(path, "com.apple.quarantine", 0)
    }

    // MARK: - Install

    /// Stage the bridge and (re)install every hook entry. Idempotent and
    /// self-repairing — safe to run on every launch.
    @discardableResult
    func installAll(bundle: Bundle = .main, fm: FileManager = .default) -> Bool {
        let haveBridge = stageBridge(from: bundle, fm: fm) != nil
            || fm.isExecutableFile(atPath: bridgePath)
        guard haveBridge else { return false }
        var ok = true
        if !installClaudeHooks(fm: fm) { ok = false }
        if !installCodexHooks(fm: fm) { ok = false }
        return ok
    }

    // MARK: Claude Code

    @discardableResult
    func installClaudeHooks(fm: FileManager = .default) -> Bool {
        if !fm.fileExists(atPath: claudeConfigDirectory) {
            try? fm.createDirectory(atPath: claudeConfigDirectory, withIntermediateDirectories: true)
        }

        // Read raw text (preserved verbatim for minimal-diff write-back).
        let originalText: String? = fm.contents(atPath: claudeSettingsPath)
            .flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (protect user data — CodeIsland #89)
        if let text = originalText, !text.isEmpty, Self.parseJSONFile(at: claudeSettingsPath, fm: fm) == nil {
            return false
        }

        let settings = Self.parseJSONFile(at: claudeSettingsPath, fm: fm) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let events = compatibleClaudeEvents()

        // Already installed (and with the current timeouts) — byte-level no-op.
        // A timeout drift from an older doisland still triggers a rewrite.
        let alreadyInstalled = events.allSatisfy { entry in
            guard let entries = hooks[entry.event] as? [[String: Any]] else { return false }
            return entries.contains { hookGroup in
                guard let hookList = hookGroup["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains {
                    ($0["command"] as? String)?.contains(bridgePath) == true
                        && ($0["timeout"] as? Int) == entry.timeout
                }
            }
        }
        if alreadyInstalled { return true }

        // Remove all managed hooks first, then re-install the compatible events.
        hooks = removeManagedHookEntries(from: hooks)
        for (event, timeout) in events {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            let hookEntry: [String: Any] = [
                "type": "command", "command": claudeHookCommand, "timeout": timeout,
            ]
            eventHooks.append(["matcher": "", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }

        backupClaudeSettings(originalText: originalText, fm: fm)
        return writeJSON(topLevelKey: "hooks", value: hooks, into: originalText, at: claudeSettingsPath, fm: fm)
    }

    func uninstallClaudeHooks(fm: FileManager = .default) {
        guard let root = Self.parseJSONFile(at: claudeSettingsPath, fm: fm),
              var hooks = root["hooks"] as? [String: Any],
              let originalText = fm.contents(atPath: claudeSettingsPath)
                  .flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        hooks = removeManagedHookEntries(from: hooks)

        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: "hooks")
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: "hooks", value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            Self.write(data, to: claudeSettingsPath, fm: fm)
        }
    }

    private func backupClaudeSettings(originalText: String?, fm: FileManager) {
        guard let originalText, !originalText.isEmpty else { return } // nothing to lose
        guard !fm.fileExists(atPath: claudeSettingsBackupPath) else { return } // first modification only
        fm.createFile(atPath: claudeSettingsBackupPath, contents: Data(originalText.utf8))
    }

    // MARK: Codex

    @discardableResult
    func installCodexHooks(fm: FileManager = .default) -> Bool {
        // Codex not on this machine — skip quietly instead of creating ~/.codex.
        guard fm.fileExists(atPath: codexHomeDirectory) else { return true }

        let originalText: String? = fm.contents(atPath: codexHooksPath)
            .flatMap { String(data: $0, encoding: .utf8) }
        if let text = originalText, !text.isEmpty, Self.parseJSONFile(at: codexHooksPath, fm: fm) == nil {
            return false
        }

        let root = Self.parseJSONFile(at: codexHooksPath, fm: fm) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Already installed (and with the current timeouts) — byte-level no-op;
        // JSONSerialization key order is not stable enough to rewrite every launch.
        let alreadyInstalled = Self.codexEvents.allSatisfy { entry in
            guard let entries = hooks[entry.event] as? [[String: Any]] else { return false }
            return entries.contains { hookGroup in
                guard let hookList = hookGroup["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains {
                    ($0["command"] as? String)?.contains(bridgePath) == true
                        && ($0["timeout"] as? Int) == entry.timeout
                }
            }
        }
        if alreadyInstalled { return true }

        hooks = removeManagedHookEntries(from: hooks)

        for (event, timeout) in Self.codexEvents {
            var eventEntries = hooks[event] as? [[String: Any]] ?? []
            eventEntries.removeAll { containsOurHook($0) }
            let entry: [String: Any] = [
                "hooks": [["type": "command", "command": codexHookCommand, "timeout": timeout] as [String: Any]],
            ]
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        guard writeJSON(topLevelKey: "hooks", value: hooks, into: originalText, at: codexHooksPath, fm: fm) else {
            return false
        }
        // A hooks.json without the activation flag is not an installed Codex integration.
        return enableCodexHooksConfig(fm: fm)
    }

    func uninstallCodexHooks(fm: FileManager = .default) {
        guard let root = Self.parseJSONFile(at: codexHooksPath, fm: fm),
              var hooks = root["hooks"] as? [String: Any],
              let originalText = fm.contents(atPath: codexHooksPath)
                  .flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        hooks = removeManagedHookEntries(from: hooks)

        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: "hooks")
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: "hooks", value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            Self.write(data, to: codexHooksPath, fm: fm)
        }
        // config.toml's features.hooks flag is left as-is: without hook entries
        // it is inert, and it may pre-date us.
    }

    /// Ensure `hooks = true` under `[features]` in Codex's config.toml.
    private func enableCodexHooksConfig(fm: FileManager) -> Bool {
        try? fm.createDirectory(
            atPath: (codexConfigTomlPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let contents: String
        if fm.fileExists(atPath: codexConfigTomlPath),
           let existing = try? String(contentsOfFile: codexConfigTomlPath, encoding: .utf8) {
            contents = existing
        } else {
            contents = ""
        }
        guard let result = CodexHooksConfig.enablingHooks(in: contents) else { return false }
        if result == contents { return true }
        return Self.write(Data(result.utf8), to: codexConfigTomlPath, fm: fm)
    }

    // MARK: - Uninstall

    /// Remove every hook entry we own plus the staged bridge and backup file.
    func uninstallAll(fm: FileManager = .default) {
        uninstallClaudeHooks(fm: fm)
        uninstallCodexHooks(fm: fm)
        try? fm.removeItem(atPath: bridgePath)
        try? fm.removeItem(atPath: claudeSettingsBackupPath)
    }

    // MARK: - Detection helpers

    /// Drop our entries from a `hooks` mapping; event keys whose entry list
    /// becomes empty are removed entirely.
    private func removeManagedHookEntries(from hooks: [String: Any]) -> [String: Any] {
        var cleaned = hooks
        for (event, value) in cleaned {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { containsOurHook($0) }
            if entries.isEmpty {
                cleaned.removeValue(forKey: event)
            } else {
                cleaned[event] = entries
            }
        }
        return cleaned
    }

    /// A hook entry is ours when any of its commands references our staged
    /// bridge path (quoted or not).
    private func containsOurHook(_ entry: [String: Any]) -> Bool {
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains { ($0["command"] as? String)?.contains(bridgePath) == true }
        }
        if let cmd = entry["command"] as? String {
            return cmd.contains(bridgePath)
        }
        return false
    }

    private func compatibleClaudeEvents() -> [(event: String, timeout: Int)] {
        guard let version = claudeVersionProvider() else {
            // Undetectable version — see the header for this simplification.
            return Self.claudeEvents
        }
        return Self.claudeEvents.filter { entry in
            guard let minVer = Self.claudeVersionGatedEvents[entry.event] else { return true }
            return Self.versionAtLeast(version, minVer)
        }
    }

    // MARK: - JSON / file plumbing

    /// Minimal-diff write of a single top-level key, preserving user comments /
    /// key order / escaping. Creates the file fresh when `originalText` is nil.
    private func writeJSON(
        topLevelKey key: String,
        value: Any,
        into originalText: String?,
        at path: String,
        fm: FileManager
    ) -> Bool {
        let source: String = {
            if let t = originalText, !t.isEmpty { return t }
            return "{}\n"
        }()
        guard let merged = JSONMinimalEditor.setTopLevelValue(in: source, key: key, value: value) else {
            return false
        }
        return Self.write(Data(merged.utf8), to: path, fm: fm)
    }

    /// `FileManager.createFile` at a symlinked file's target, so a symlinked
    /// `settings.json` (dotfiles, one file shared between accounts) survives
    /// the write (simplified from CodeIsland's ConfigPathIdentity.write).
    @discardableResult
    private static func write(_ data: Data, to path: String, fm: FileManager) -> Bool {
        if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            let target = dest.hasPrefix("/") ? dest : parent + "/" + dest
            if fm.createFile(atPath: target, contents: data) { return true }
        }
        return fm.createFile(atPath: path, contents: data)
    }

    /// Parse a JSON file, stripping JSONC comments first. Nil for a missing or
    /// unparseable file.
    static func parseJSONFile(at path: String, fm: FileManager) -> [String: Any]? {
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let stripped = stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return nil }
        return json
    }

    /// Strip `//` line and `/* */` block comments, string literals preserved.
    static func stripJSONComments(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex
        while i < end {
            let c = input[i]
            if c == "\"" {
                result.append(c)
                i = input.index(after: i)
                while i < end {
                    let sc = input[i]
                    result.append(sc)
                    if sc == "\\" {
                        i = input.index(after: i)
                        if i < end { result.append(input[i]) }
                    } else if sc == "\"" {
                        break
                    }
                    i = input.index(after: i)
                }
                if i < end { i = input.index(after: i) }
                continue
            }
            let next = input.index(after: i)
            if c == "/" && next < end {
                let nc = input[next]
                if nc == "/" {
                    i = input.index(after: next)
                    while i < end && input[i] != "\n" { i = input.index(after: i) }
                    continue
                } else if nc == "*" {
                    i = input.index(after: next)
                    while i < end {
                        let bi = input.index(after: i)
                        if input[i] == "*" && bi < end && input[bi] == "/" {
                            i = input.index(after: bi)
                            break
                        }
                        i = input.index(after: i)
                    }
                    continue
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }

    // MARK: - Claude Code version detection

    /// Detect the installed Claude Code version by running `claude --version`
    /// (5s watchdog: a stuck `claude` used to freeze app launch — CodeIsland #139).
    static func detectClaudeVersion(homeDirectory: String) -> String? {
        guard let claudePath = claudeBinaryCandidates(homeDirectory: homeDirectory)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        guard let output = runCommand(path: claudePath, args: ["--version"], timeout: 5) else { return nil }
        // Parse "2.1.92 (Claude Code)" → "2.1.92"
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").first ?? ""
        return version.isEmpty ? nil : version
    }

    /// Where `claude` lives, in the order a login shell would usually find it.
    static func claudeBinaryCandidates(homeDirectory: String) -> [String] {
        [
            homeDirectory + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            homeDirectory + "/.claude/local/claude",
        ]
    }

    /// Compare semver strings: returns true if `installed` >= `required`
    static func versionAtLeast(_ installed: String, _ required: String) -> Bool {
        let i = installed.split(separator: ".").compactMap { Int($0) }
        let r = required.split(separator: ".").compactMap { Int($0) }
        for idx in 0..<max(i.count, r.count) {
            let iv = idx < i.count ? i[idx] : 0
            let rv = idx < r.count ? r[idx] : 0
            if iv > rv { return true }
            if iv < rv { return false }
        }
        return true // equal
    }

    private static func runCommand(path: String, args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        nonisolated(unsafe) let watched = proc
        let watchdog = DispatchWorkItem {
            if watched.isRunning { watched.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }
}
