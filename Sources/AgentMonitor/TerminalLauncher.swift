import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Sendable {
    case terminal
    case iTerm2
    case auto

    static func preferred(from metadata: [String: String]) -> TerminalApp {
        let raw = (metadata["terminal_app"] ?? metadata["terminalApp"] ?? metadata["terminal_emulator"] ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "terminal", "terminal.app", "apple terminal", "apple-terminal":
            return .terminal
        case "iterm", "iterm2", "iterm.app", "iterm2.app", "com.googlecode.iterm2":
            return .iTerm2
        default:
            return .auto
        }
    }

    var searchOrder: [TerminalApp] {
        switch self {
        case .terminal:
            [.terminal, .iTerm2]
        case .iTerm2:
            [.iTerm2, .terminal]
        case .auto:
            [.terminal, .iTerm2]
        }
    }

    var openFallback: TerminalApp {
        switch self {
        case .terminal, .auto:
            .terminal
        case .iTerm2:
            .iTerm2
        }
    }
}

struct TerminalLaunchPlan: Equatable {
    var tags: [String]
    var cwd: String?
    var fallbackTag: String
    var preferredApp: TerminalApp

    init(agent: AgentRecord) {
        let metadata = agent.metadata
        self.tags = TerminalLaunchPlan.candidateTags(for: agent)
        self.cwd = metadata["cwd"] ?? metadata["working_directory"] ?? metadata["path"]
        self.fallbackTag = tags.first ?? agent.id
        self.preferredApp = TerminalApp.preferred(from: metadata)
    }

    static func candidateTags(for agent: AgentRecord) -> [String] {
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
}

enum TerminalLauncher {
    static func openTerminal(for agent: AgentRecord) {
        let plan = TerminalLaunchPlan(agent: agent)

        if !plan.tags.isEmpty {
            for app in plan.preferredApp.searchOrder {
                if runAppleScript(focusExistingTerminalScript(app: app, tags: plan.tags)) {
                    return
                }
            }
        }

        runAppleScript(openNewTerminalScript(app: plan.preferredApp.openFallback, cwd: plan.cwd, tag: plan.fallbackTag))
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

    static func focusExistingTerminalScript(app: TerminalApp, tags: [String]) -> String {
        switch app {
        case .terminal, .auto:
            return focusTerminalAppScript(tags: tags)
        case .iTerm2:
            return focusITerm2Script(tags: tags)
        }
    }

    static func openNewTerminalScript(app: TerminalApp, cwd: String?, tag: String) -> String {
        switch app {
        case .terminal, .auto:
            return openTerminalAppScript(cwd: cwd, tag: tag)
        case .iTerm2:
            return openITerm2Script(cwd: cwd, tag: tag)
        }
    }

    static func focusTerminalAppScript(tags: [String]) -> String {
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

    static func focusITerm2Script(tags: [String]) -> String {
        let tagList = tags.map(appleScriptString).joined(separator: ", ")
        return """
        set targetTags to {\(tagList)}
        tell application "iTerm2"
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with s in sessions of tb
                        repeat with targetTag in targetTags
                            set matched to false
                            try
                                if name of s contains targetTag then set matched to true
                            end try
                            try
                                if tty of s contains targetTag then set matched to true
                            end try
                            if matched then
                                select s
                                select tb
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end repeat
            end repeat
        end tell
        error "no matching iTerm2 session"
        """
    }

    static func openTerminalAppScript(cwd: String?, tag: String) -> String {
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

    static func openITerm2Script(cwd: String?, tag: String) -> String {
        let directory = cwd.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let shellDirectory = shellSingleQuoted(directory)
        let title = shellSingleQuoted(tag)
        let command = "cd \(shellDirectory); printf '\\e]0;%s\\a' \(title); clear"
        let quotedCommand = appleScriptString(command)
        return """
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current window
                create tab with default profile command \(quotedCommand)
            end tell
        end tell
        """
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        + "\""
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
