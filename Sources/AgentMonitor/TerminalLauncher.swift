import AppKit
import Foundation

enum TerminalLauncher {
    static func openTerminal(for agent: AgentRecord) {
        let metadata = agent.metadata
        let tags = candidateTags(for: agent)
        let cwd = metadata["cwd"] ?? metadata["working_directory"] ?? metadata["path"]
        let fallbackTag = tags.first ?? agent.id

        if !tags.isEmpty, runAppleScript(focusExistingTerminalScript(tags: tags)) {
            return
        }
        runAppleScript(openNewTerminalScript(cwd: cwd, tag: fallbackTag))
    }

    private static func candidateTags(for agent: AgentRecord) -> [String] {
        let metadata = agent.metadata
        let raw = [
            metadata["terminal_tag"],
            metadata["terminalTag"],
            metadata["terminal"],
            metadata["tty"],
            metadata["session_id"],
            agent.id,
        ]

        var tags: [String] = []
        for value in raw.compactMap({ $0 }) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "not a tty", trimmed != "??" else { continue }
            appendUnique(trimmed, to: &tags)
            if trimmed.hasPrefix("/dev/") {
                appendUnique(String(trimmed.dropFirst("/dev/".count)), to: &tags)
            } else if trimmed.hasPrefix("ttys") || trimmed.hasPrefix("tty") {
                appendUnique("/dev/\(trimmed)", to: &tags)
            }
        }
        return tags
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    @discardableResult
    private static func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("AgentMonitor could not run osascript: \(error.localizedDescription)")
            return false
        }
    }

    private static func focusExistingTerminalScript(tags: [String]) -> String {
        let tagList = tags.map(appleScriptString).joined(separator: ", ")
        return """
        set targetTags to {\(tagList)}
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with targetTag in targetTags
                        set matched to false
                        try
                            if custom title of t contains targetTag then set matched to true
                        end try
                        try
                            if name of t contains targetTag then set matched to true
                        end try
                        try
                            if tty of t contains targetTag then set matched to true
                        end try
                        if matched then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        error "no matching Terminal tab"
        """
    }

    private static func openNewTerminalScript(cwd: String?, tag: String) -> String {
        let directory = cwd.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let shellDirectory = shellSingleQuoted(directory)
        let title = shellSingleQuoted(tag)
        let command = "cd \(shellDirectory); printf '\\e]0;%s\\a' \(title); clear"
        let quotedCommand = appleScriptString(command)
        return """
        tell application "Terminal"
            activate
            do script \(quotedCommand)
        end tell
        """
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        + "\""
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
