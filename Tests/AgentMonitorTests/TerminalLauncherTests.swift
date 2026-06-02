import XCTest
@testable import AgentMonitor

final class TerminalLauncherTests: XCTestCase {
    func testCandidateTagsNormalizeTTYFormsAndIgnoreBogusValues() {
        let agent = AgentRecord(
            id: "agent-1",
            state: .yellow,
            metadata: [
                "terminal_tag": " /dev/ttys123 ",
                "tty": "not a tty",
                "session_id": "session-1",
            ]
        )

        XCTAssertEqual(
            TerminalLaunchPlan.candidateTags(for: agent),
            ["/dev/ttys123", "ttys123", "session-1", "agent-1"]
        )
    }

    func testPreferredTerminalAppParsingAndSearchOrder() {
        XCTAssertEqual(TerminalApp.preferred(from: ["terminal_app": "iTerm2"]), .iTerm2)
        XCTAssertEqual(TerminalApp.preferred(from: ["terminal_app": "Terminal.app"]), .terminal)
        XCTAssertEqual(TerminalApp.preferred(from: [:]), .auto)

        XCTAssertEqual(TerminalApp.iTerm2.searchOrder, [.iTerm2, .terminal])
        XCTAssertEqual(TerminalApp.terminal.searchOrder, [.terminal, .iTerm2])
    }

    func testTerminalAppFocusScriptUsesTerminalDictionary() {
        let script = TerminalLauncher.focusExistingTerminalScript(app: .terminal, tags: ["ttys001", "/dev/ttys001"])

        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("tabs of w"))
        XCTAssertTrue(script.contains("tty of t"))
        XCTAssertTrue(script.contains("ttys001"))
        XCTAssertTrue(script.contains("/dev/ttys001"))
    }

    func testITerm2FocusScriptUsesITerm2Dictionary() {
        let script = TerminalLauncher.focusExistingTerminalScript(app: .iTerm2, tags: ["ttys002"])

        XCTAssertTrue(script.contains("tell application \"iTerm2\""))
        XCTAssertTrue(script.contains("sessions of tb"))
        XCTAssertTrue(script.contains("tty of s"))
        XCTAssertTrue(script.contains("select s"))
        XCTAssertTrue(script.contains("ttys002"))
    }

    func testOpenScriptsRespectPreferredTerminalAppAndCwd() {
        let terminalScript = TerminalLauncher.openNewTerminalScript(app: .terminal, cwd: "/tmp/agent monitor", tag: "tag's value")
        XCTAssertTrue(terminalScript.contains("tell application \"Terminal\""))
        XCTAssertTrue(terminalScript.contains("cd '/tmp/agent monitor'"))
        XCTAssertTrue(terminalScript.contains("tag"))
        XCTAssertTrue(terminalScript.contains("s value"))

        let iTermScript = TerminalLauncher.openNewTerminalScript(app: .iTerm2, cwd: "/tmp/agent monitor", tag: "agent-tag")
        XCTAssertTrue(iTermScript.contains("tell application \"iTerm2\""))
        XCTAssertTrue(iTermScript.contains("create tab with default profile command"))
        XCTAssertTrue(iTermScript.contains("cd '/tmp/agent monitor'"))
    }
}
