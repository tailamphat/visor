import Testing
import VisorCore

@Suite struct TerminalCommandTests {
    @Test func everyCatalogCommandIsTypedNotRun() {
        var count = 0
        for tool in ReleaseTool.all {
            for method in InstallMethod.allCases {
                guard let command = tool.updateCommand(method) else { continue }
                count += 1
                let script = TerminalCommand.appleScript(typing: command)
                #expect(script != nil, "\(command)")
                #expect(script?.contains("print -z -- '\(command)'") == true)
                // The command only ever appears inside single quotes.
                #expect(script?.contains("do script \"\(command)") == false)
            }
        }
        #expect(count > 8)
    }

    @Test func refusesAnythingNotPlain() {
        for bad in ["", "rm -rf ~; x", "a\"b", "a'b", "a\\b", "a\nb", "a$(x)", "a`x`", "a|b", "a&b", "a>b", "a*b",
                    "é", String(repeating: "a", count: 121)] {
            #expect(TerminalCommand.appleScript(typing: bad) == nil, "\(bad)")
        }
    }

    @Test func lineStartsWithASpace() {
        #expect(TerminalCommand.appleScript(typing: "brew upgrade x")?.contains("do script \" print -z -- 'brew upgrade x'\"") == true)
    }

    @Test func detectsZsh() {
        #expect(TerminalCommand.isZsh("/bin/zsh") && TerminalCommand.isZsh("/opt/homebrew/bin/zsh"))
        #expect(!TerminalCommand.isZsh("/bin/bash") && !TerminalCommand.isZsh("/usr/bin/fish") && !TerminalCommand.isZsh(nil) && !TerminalCommand.isZsh("/bin/zshx"))
    }

    @Test func escapesForAppleScript() {
        #expect(TerminalCommand.escaped("a\"b\\c") == "a\\\"b\\\\c")
    }
}
