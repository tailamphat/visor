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
                #expect(script?.contains("print -z '\(command)'") == true)
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

    @Test func escapesForAppleScript() {
        #expect(TerminalCommand.escaped("a\"b\\c") == "a\\\"b\\\\c")
    }
}
